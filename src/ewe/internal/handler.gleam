import ewe/internal/encoder
import ewe/internal/exception
import ewe/internal/http.{
  type Connection, type ResponseBody, BitsData, BytesData, Empty, StringTreeData,
  TextData, WebsocketConnection,
} as http_
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/option
import gleam/result
import glisten
import glisten/transport

type ExitReason {
  Normal
  Abnormal(reason: String)
}

type Next {
  Continue
  Stop(ExitReason)
}

pub fn loop(
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
) -> glisten.Loop(Connection, a) {
  fn(http_conn, msg, _conn) {
    let assert glisten.Packet(msg) = msg

    http_.parse_request(http_conn, msg)
    |> result.map(fn(req) {
      case call_handler(req, handler, on_crash) {
        Continue -> glisten.continue(http_conn)
        Stop(Normal) -> glisten.stop()
        Stop(Abnormal(reason)) -> glisten.stop_abnormal(reason)
      }
    })
    |> result.replace_error(glisten.stop())
    |> result.unwrap_both()
  }
}

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
