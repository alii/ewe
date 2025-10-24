// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import compresso
import ewe/internal/file
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result
import gleam/string
import gleam/string_tree
import logging

import glisten
import glisten/socket
import glisten/transport

import ewe/internal/buffer
import ewe/internal/encoder
import ewe/internal/exception
import ewe/internal/http.{
  type Connection, type ResponseBody, BitsData, BytesData, Chunked, Empty, File,
  SSE, StringTreeData, TextData, Websocket,
} as ewe_http

// -----------------------------------------------------------------------------
// PUBLIC TYPES
// -----------------------------------------------------------------------------

// Custom message that can be sent to or received from the Glisten actor
pub type GlistenMessage {
  IdleTimeout
}

// State of the Glisten actor
pub type GlistenState {
  GlistenState(
    timer: Option(process.Timer),
    subject: process.Subject(GlistenMessage),
  )
}

// -----------------------------------------------------------------------------
// INTERNAL TYPES
// -----------------------------------------------------------------------------

// Control flow for the handler loop
type Next {
  Continue(new_state: GlistenState)
  Stop
}

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Initializes the Glisten actor's state and selector for custom messages
pub fn init(_) -> #(GlistenState, Option(process.Selector(GlistenMessage))) {
  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subject)

  #(GlistenState(None, subject), Some(selector))
}

/// Main handler loop that processes HTTP requests
pub fn loop(
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  factory_name: process.Name(
    factory.Message(fn() -> Result(actor.Started(Nil), actor.StartError), Nil),
  ),
  idle_timeout: Int,
) -> glisten.Loop(GlistenState, GlistenMessage) {
  fn(
    state: GlistenState,
    msg: glisten.Message(GlistenMessage),
    conn: glisten.Connection(GlistenMessage),
  ) -> glisten.Next(GlistenState, glisten.Message(GlistenMessage)) {
    case msg {
      glisten.User(IdleTimeout) -> glisten.stop()
      glisten.Packet(msg) -> {
        case state.timer {
          Some(timer) -> process.cancel_timer(timer)
          None -> process.TimerNotFound
        }

        let http_conn = ewe_http.transform_connection(conn, factory_name)

        let parsed = ewe_http.parse_request(http_conn, buffer.new(msg))

        case parsed {
          Ok(ewe_http.Http1Request(req, version)) ->
            case
              call_handler(
                req,
                version,
                state.subject,
                handler,
                on_crash,
                idle_timeout,
              )
            {
              Continue(new_state) -> glisten.continue(new_state)
              Stop -> {
                glisten.stop()
              }
            }

          Ok(ewe_http.Http2Upgrade(_data)) -> {
            logging.log(logging.Debug, "Received HTTP/2 upgrade request")
            glisten.stop()
          }

          Ok(ewe_http.Http2CleartextUpgrade(_req, _settings)) -> {
            logging.log(
              logging.Debug,
              "Received HTTP/2 cleartext upgrade request",
            )
            glisten.stop()
          }

          Error(reason) -> {
            let status = case reason {
              ewe_http.InvalidVersion -> 505
              _ -> 400
            }

            logging.log(
              logging.Error,
              "Received invalid request: " <> string.inspect(reason),
            )

            let _ =
              response.new(status)
              |> response.set_body(<<>>)
              |> response.set_header("connection", "close")
              |> encoder.encode_response()
              |> transport.send(http_conn.transport, http_conn.socket, _)

            glisten.stop()
          }
        }
      }
    }
  }
}

// -----------------------------------------------------------------------------
// REQUEST HANDLING
// -----------------------------------------------------------------------------

/// Calls the user-provided handler function with error handling
fn call_handler(
  req: request.Request(Connection),
  version: ewe_http.HttpVersion,
  subject: process.Subject(GlistenMessage),
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  idle_timeout: Int,
) -> Next {
  let resp = case exception.rescue(fn() { handler(req) }) {
    Ok(resp) -> resp
    Error(e) -> {
      logging.log(logging.Error, string.inspect(e))

      response.set_header(on_crash, "connection", "close")
    }
  }

  case resp.body {
    Websocket | SSE | Chunked -> Stop
    File(descriptor, offset, size) -> {
      let sent = handle_resp_file(req, version, resp, descriptor, offset, size)

      case sent, is_connection_close(resp) {
        Ok(Nil), False -> {
          let timer = process.send_after(subject, idle_timeout, IdleTimeout)
          Continue(GlistenState(Some(timer), subject))
        }
        _, _ -> Stop
      }
    }
    _ -> {
      let sent = handle_resp_body(req, version, resp, resp.body)
      case sent, is_connection_close(resp) {
        Ok(Nil), False -> {
          let timer = process.send_after(subject, idle_timeout, IdleTimeout)
          Continue(GlistenState(Some(timer), subject))
        }
        _, _ -> Stop
      }
    }
  }
}

// -----------------------------------------------------------------------------
// RESPONSE HANDLING
// -----------------------------------------------------------------------------

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
