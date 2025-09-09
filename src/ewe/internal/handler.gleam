// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import ewe/internal/file
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/option
import gleam/result
import glisten/socket

import glisten
import glisten/transport

import ewe/internal/buffer
import ewe/internal/encoder
import ewe/internal/exception
import ewe/internal/http.{
  type Connection, type ResponseBody, BitsData, BytesData, Empty, File,
  StringTreeData, TextData, WebsocketConnection,
} as http_

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

// Control flow for the handler loop
type Next {
  Continue
  Stop
}

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Main handler loop that processes HTTP requests
pub fn loop(
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
) -> glisten.Loop(Nil, a) {
  fn(state, msg, conn) {
    let assert glisten.Packet(msg) = msg
    let http_conn = http_.transform_connection(conn)

    let parsed = http_.parse_request(http_conn, buffer.new(msg))

    case parsed {
      Ok(req) ->
        case call_handler(req, handler, on_crash) {
          Continue -> glisten.continue(state)
          Stop -> glisten.stop()
        }

      Error(reason) -> {
        let status = case reason {
          http_.InvalidVersion -> 505
          _ -> 400
        }

        let _ =
          response.new(status)
          |> response.set_body(bytes_tree.new())
          |> response.set_header("connection", "close")
          |> encoder.encode_response()
          |> transport.send(http_conn.transport, http_conn.socket, _)

        glisten.stop()
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
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
) -> Next {
  let resp =
    exception.rescue(fn() { handler(req) })
    |> result.map_error(fn(_e) {
      on_crash |> response.set_header("connection", "close")
    })
    |> result.unwrap_both()

  case resp {
    Response(body: WebsocketConnection(selector), ..) -> {
      let _ = process.selector_receive_forever(selector)
      Stop
    }
    Response(body: File(descriptor, size), ..) ->
      handle_resp_file(req, resp, descriptor, size)
    Response(body: body, ..) -> handle_resp_body(req, resp, body)
  }
}

// -----------------------------------------------------------------------------
// RESPONSE HANDLING
// -----------------------------------------------------------------------------

fn handle_resp_file(
  req: Request(Connection),
  resp: Response(ResponseBody),
  descriptor: file.IoDevice,
  size: Int,
) -> Next {
  let assert option.Some(http_version) = req.body.http_version

  let resp =
    response.set_body(resp, bytes_tree.new())
    |> http_.append_default_headers(req, http_version)

  let sent =
    encoder.setup_encoded_response(resp)
    |> transport.send(req.body.transport, req.body.socket, _)
    |> result.try(fn(_) {
      file.send(req.body.transport, req.body.socket, descriptor, size)
      |> result.replace_error(socket.Badarg)
    })

  let _ = file.close(descriptor)

  case sent, is_connection_close(resp) {
    Ok(Nil), False -> Continue
    _, _ -> Stop
  }
}

/// Handles the response body and sends it to the client
fn handle_resp_body(
  req: Request(Connection),
  resp: Response(ResponseBody),
  body: ResponseBody,
) -> Next {
  let assert option.Some(http_version) = req.body.http_version

  let bytes = case body {
    TextData(text) -> bytes_tree.from_string(text)
    StringTreeData(string_tree) -> bytes_tree.from_string_tree(string_tree)
    BitsData(bits) -> bytes_tree.from_bit_array(bits)
    BytesData(bytes) -> bytes
    Empty -> bytes_tree.new()
    _ -> panic
  }

  let sent =
    response.set_body(resp, bytes)
    |> http_.append_default_headers(req, http_version)
    |> encoder.encode_response()
    |> transport.send(req.body.transport, req.body.socket, _)

  case sent, is_connection_close(resp) {
    Ok(Nil), False -> Continue
    _, _ -> Stop
  }
}

fn is_connection_close(resp: Response(a)) -> Bool {
  case response.get_header(resp, "connection") {
    Ok("close") -> True
    _ -> False
  }
}
