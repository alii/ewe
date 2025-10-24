import compresso
import ewe/internal/buffer
import ewe/internal/encoder
import ewe/internal/exception
import ewe/internal/file
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import glisten/internal/handler.{Close, Internal}
import glisten/socket
import glisten/transport
import logging

import ewe/internal/http1.{
  type Connection, type ResponseBody, BitsData, BytesData, Chunked, Empty, File,
  SSE, StringTreeData, TextData, Websocket,
} as ewe_http

import glisten

pub type State {
  State(idle_timer: Option(process.Timer))
}

pub fn init() -> State {
  State(idle_timer: None)
}

pub type Message {
  IdleTimeout
}

pub type HandleResult {
  Continue(new_state: State)
  Stop
  Http2Upgrade(data: BitArray)
  Http2CleartextUpgrade(req: Request(ewe_http.Connection), settings: String)
}

pub fn handle_packet(
  state: State,
  msg: BitArray,
  conn: Connection,
  subject: process.Subject(handler.Message(_)),
  handler: fn(Request(ewe_http.Connection)) -> Response(ewe_http.ResponseBody),
  on_crash: Response(ewe_http.ResponseBody),
  idle_timeout: Int,
) -> HandleResult {
  case state.idle_timer {
    Some(timer) -> process.cancel_timer(timer)
    None -> process.TimerNotFound
  }

  let parsed = ewe_http.parse_request(conn, buffer.new(msg))

  case parsed {
    Ok(ewe_http.Http1Request(req, version)) -> {
      let called =
        call_handler(req, version, subject, handler, on_crash, idle_timeout)
      case called {
        Ok(state) -> Continue(state)
        Error(Nil) -> Stop
      }
    }

    Ok(ewe_http.Http2Upgrade(data)) -> Http2Upgrade(data)

    Ok(ewe_http.Http2CleartextUpgrade(req, settings)) ->
      Http2CleartextUpgrade(req, settings)

    Error(reason) -> {
      let status = case reason {
        ewe_http.InvalidVersion -> 505
        _ -> 400
      }

      let _ =
        response.new(status)
        |> response.set_body(<<>>)
        |> response.set_header("connection", "close")
        |> encoder.encode_response()
        |> transport.send(conn.transport, conn.socket, _)

      Stop
    }
  }
}

fn call_handler(
  req: Request(ewe_http.Connection),
  version: ewe_http.HttpVersion,
  subject: process.Subject(handler.Message(user_message)),
  handler: fn(Request(ewe_http.Connection)) -> Response(ewe_http.ResponseBody),
  on_crash: Response(ewe_http.ResponseBody),
  idle_timeout: Int,
) -> Result(State, Nil) {
  let resp = case exception.rescue(fn() { handler(req) }) {
    Ok(resp) -> resp
    Error(e) -> {
      logging.log(logging.Error, string.inspect(e))

      response.set_header(on_crash, "connection", "close")
    }
  }

  case resp.body {
    Websocket | SSE | Chunked -> Error(Nil)
    File(descriptor, offset, size) -> {
      let sent = handle_resp_file(req, version, resp, descriptor, offset, size)

      case sent, is_connection_close(resp) {
        Ok(Nil), False -> {
          let timer = process.send_after(subject, idle_timeout, Internal(Close))
          Ok(State(Some(timer)))
        }
        _, _ -> Error(Nil)
      }
    }
    _ -> {
      let sent = handle_resp_body(req, version, resp, resp.body)
      case sent, is_connection_close(resp) {
        Ok(Nil), False -> {
          let timer = process.send_after(subject, idle_timeout, Internal(Close))
          Ok(State(Some(timer)))
        }
        _, _ -> Error(Nil)
      }
    }
  }
}

/// Handles the file response body and sends it to the client
fn handle_resp_file(
  req: Request(Connection),
  version: ewe_http.HttpVersion,
  resp: Response(ResponseBody),
  descriptor: file.IoDevice,
  offset: Int,
  size: Int,
) -> Result(Nil, glisten.SocketReason) {
  let resp = case response.get_header(resp, "content-length") {
    Ok(_) -> resp
    Error(Nil) ->
      response.set_header(resp, "content-length", int.to_string(size))
  }

  let sent =
    ewe_http.append_default_headers(resp, req, version)
    |> encoder.setup_encoded_response()
    |> transport.send(req.body.transport, req.body.socket, _)
    |> result.try(fn(_) {
      file.send(req.body.transport, req.body.socket, descriptor, offset, size)
      |> result.replace_error(socket.Badarg)
    })

  let _ = file.close(descriptor)

  sent
}

/// Handles the response body and sends it to the client
fn handle_resp_body(
  req: Request(Connection),
  version: ewe_http.HttpVersion,
  resp: Response(ResponseBody),
  body: ResponseBody,
) -> Result(Nil, glisten.SocketReason) {
  let bits = case body {
    TextData(text) -> bit_array.from_string(text)
    StringTreeData(string_tree) ->
      string_tree.to_string(string_tree) |> bit_array.from_string
    BitsData(bits) -> bits
    BytesData(bytes) -> bytes_tree.to_bit_array(bytes)
    Empty -> <<>>
    _ -> panic
  }

  let content_length = bit_array.byte_size(bits)

  let resp = case content_length > 1024 {
    True ->
      case encode_gzip(req, resp) {
        True -> {
          let compressed = compresso.gzip(bits)
          let content_length = bit_array.byte_size(compressed)

          remove_charset(resp)
          |> response.set_header("content-encoding", "gzip")
          |> response.set_header("vary", "Accept-Encoding")
          |> response.set_header(
            "content-length",
            int.to_string(content_length),
          )
          |> response.set_body(compressed)
        }
        _ ->
          response.set_body(resp, bits)
          |> response.set_header(
            "content-length",
            int.to_string(content_length),
          )
      }
    False ->
      response.set_body(resp, bits)
      |> response.set_header("content-length", int.to_string(content_length))
  }

  ewe_http.append_default_headers(resp, req, version)
  |> encoder.encode_response()
  |> transport.send(req.body.transport, req.body.socket, _)
}

fn encode_gzip(req: Request(ewe_http.Connection), resp: Response(a)) -> Bool {
  let req =
    request.get_header(req, "accept-encoding")
    |> result.map(string.contains(_, "gzip"))

  let resp = response.get_header(resp, "content-encoding")

  case req, resp {
    Ok(True), Error(Nil) -> True
    _, _ -> False
  }
}

fn remove_charset(resp: Response(a)) -> Response(a) {
  response.get_header(resp, "content-type")
  |> result.try(string.split_once(_, ";"))
  |> result.map(fn(parts) { response.set_header(resp, "content-type", parts.0) })
  |> result.unwrap(resp)
}

fn is_connection_close(resp: Response(a)) -> Bool {
  case response.get_header(resp, "connection") {
    Ok("close") -> True
    _ -> False
  }
}
