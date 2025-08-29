import ewe/internal/exception
import ewe/internal/http as http_
import ewe/internal/response as response_
import gleam/bytes_tree.{type BytesTree}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option
import gleam/result
import glisten
import glisten/socket
import glisten/transport

pub fn loop(
  handler: fn(Request(http_.Connection)) -> Response(BytesTree),
  on_crash: Response(BytesTree),
) -> glisten.Loop(http_.Connection, a) {
  fn(http_conn, msg, _conn) {
    let assert glisten.Packet(msg) = msg

    http_.parse_request(http_conn, msg)
    |> result.map(fn(req) {
      case run(req, handler, on_crash) {
        Ok(Nil) -> glisten.continue(http_conn)
        Error(_exception) -> glisten.stop()
      }
    })
    |> result.replace_error(glisten.stop())
    |> result.unwrap_both()
  }
}

fn run(
  req: request.Request(http_.Connection),
  handler: fn(Request(http_.Connection)) -> Response(BytesTree),
  on_crash: Response(BytesTree),
) -> Result(Nil, socket.SocketReason) {
  let assert option.Some(http_version) = req.body.http_version

  exception.rescue(fn() { handler(req) })
  |> result.map_error(fn(e) {
    echo e
    on_crash
  })
  |> result.unwrap_both()
  |> http_.append_default_headers(http_version)
  |> response_.encode()
  |> transport.send(req.body.transport, req.body.socket, _)
}
