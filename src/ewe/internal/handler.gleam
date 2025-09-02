// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/option
import gleam/result

import glisten
import glisten/transport

import ewe/internal/buffer
import ewe/internal/encoder
import ewe/internal/exception
import ewe/internal/http.{
  type Connection, type ResponseBody, BitsData, BytesData, Empty, StringTreeData,
  TextData, WebsocketConnection,
} as http_

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

// Represents the reason for exiting the handler loop
type ExitReason {
  Normal
  Abnormal(reason: String)
}

// Control flow for the handler loop
type Next {
  Continue
  Stop(ExitReason)
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

    http_.parse_request(http_conn, buffer.new(msg))
    |> result.map(fn(req) {
      case call_handler(req, handler, on_crash) {
        Continue -> glisten.continue(state)
        Stop(Normal) -> glisten.stop()
        Stop(Abnormal(reason)) -> glisten.stop_abnormal(reason)
      }
    })
    |> result.replace_error(glisten.stop())
    |> result.unwrap_both()
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
    |> result.map_error(fn(_e) { on_crash })
    |> result.unwrap_both()

  case resp {
    Response(body: WebsocketConnection(selector), ..) -> {
      let _ = process.selector_receive_forever(selector)
      Stop(Normal)
    }
    Response(body: body, ..) -> handle_resp_body(req, resp, body)
  }
}

// -----------------------------------------------------------------------------
// RESPONSE HANDLING
// -----------------------------------------------------------------------------

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
    |> http_.append_default_headers(http_version)
    |> encoder.encode_response()
    |> transport.send(req.body.transport, req.body.socket, _)

  case sent {
    Ok(Nil) -> Continue
    Error(_) -> Stop(Normal)
  }
}
