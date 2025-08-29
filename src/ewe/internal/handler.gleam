import ewe/internal/exception
import ewe/internal/http as http_
import ewe/internal/response as response_
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/result
import glisten
import glisten/socket
import glisten/transport

pub fn loop(
  handler: http_.Handler,
  on_crash: response.Response(bytes_tree.BytesTree),
) -> glisten.Loop(http_.Connection, a) {
  fn(http_conn, msg, _conn) {
    let assert glisten.Packet(msg) = msg

    http_.parse_request(http_conn, msg)
    |> result.map(fn(parsed) {
      case run(parsed.request, handler, on_crash, parsed.version) {
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
  handler: http_.Handler,
  on_crash: response.Response(bytes_tree.BytesTree),
  version: http_.HttpVersion,
) -> Result(Nil, socket.SocketReason) {
  exception.rescue(fn() { handler(req) })
  |> result.map_error(fn(e) {
    echo e
    on_crash
  })
  |> result.unwrap_both()
  |> response_.append_default_headers(version)
  |> response_.encode()
  |> transport.send(req.body.transport, req.body.socket, _)
}
