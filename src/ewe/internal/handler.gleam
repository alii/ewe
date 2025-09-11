// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import ewe/internal/file
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/option.{type Option, None, Some}
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
  Continue(new_state: GlistenState)
  Stop
}

pub type GlistenMessage {
  IdleTimeout
}

pub type GlistenState {
  GlistenState(
    timer: Option(process.Timer),
    subject: process.Subject(GlistenMessage),
  )
}

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

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

        let http_conn = http_.transform_connection(conn)

        let parsed = http_.parse_request(http_conn, buffer.new(msg))

        case parsed {
          Ok(req) ->
            case
              call_handler(req, state.subject, handler, on_crash, idle_timeout)
            {
              Continue(new_state) -> glisten.continue(new_state)
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
  }
}

// -----------------------------------------------------------------------------
// REQUEST HANDLING
// -----------------------------------------------------------------------------

/// Calls the user-provided handler function with error handling
fn call_handler(
  req: request.Request(Connection),
  subject: process.Subject(GlistenMessage),
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  idle_timeout: Int,
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
    Response(body:, ..) -> {
      let sent = case body {
        File(descriptor, size) -> handle_resp_file(req, resp, descriptor, size)
        _ -> handle_resp_body(req, resp, body)
      }

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

fn handle_resp_file(
  req: Request(Connection),
  resp: Response(ResponseBody),
  descriptor: file.IoDevice,
  size: Int,
) -> Result(Nil, glisten.SocketReason) {
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

  sent
}

/// Handles the response body and sends it to the client
fn handle_resp_body(
  req: Request(Connection),
  resp: Response(ResponseBody),
  body: ResponseBody,
) -> Result(Nil, glisten.SocketReason) {
  let assert option.Some(http_version) = req.body.http_version

  let bytes = case body {
    TextData(text) -> bytes_tree.from_string(text)
    StringTreeData(string_tree) -> bytes_tree.from_string_tree(string_tree)
    BitsData(bits) -> bytes_tree.from_bit_array(bits)
    BytesData(bytes) -> bytes
    Empty -> bytes_tree.new()
    _ -> panic
  }

  response.set_body(resp, bytes)
  |> http_.append_default_headers(req, http_version)
  |> encoder.encode_response()
  |> transport.send(req.body.transport, req.body.socket, _)
}

fn is_connection_close(resp: Response(a)) -> Bool {
  case response.get_header(resp, "connection") {
    Ok("close") -> True
    _ -> False
  }
}
