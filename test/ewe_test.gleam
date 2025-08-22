import client/tcp as client
import ewe
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleeunit
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn handler(
  req: request.Request(BitArray),
) -> response.Response(bytes_tree.BytesTree) {
  case request.path_segments(req) {
    [] ->
      response.new(200)
      |> response.set_header("Content-Type", "text/plain")
      |> response.set_header("Content-Length", "13")
      |> response.set_body(bytes_tree.from_string("Hello, world!"))
    _ ->
      response.new(404)
      |> response.set_header("Content-Type", "text/plain")
      |> response.set_header("Content-Length", "9")
      |> response.set_body(bytes_tree.from_string("Not found"))
  }
}

pub fn with_http_test() {
  let assert Ok(_started) =
    ewe.new(handler)
    |> ewe.port(42_070)
    |> ewe.start()

  let assert Ok(req) = request.to("http://localhost:42070")
  let assert Ok(resp) = httpc.send(req)

  assert resp.status == 200
  assert response.get_header(resp, "Content-Type") == Ok("text/plain")
  assert resp.body == "Hello, world!"
}

pub fn with_tcp_sockets_test() {
  let assert Ok(_started) =
    ewe.new(handler)
    |> ewe.port(42_071)
    |> ewe.start()

  use socket <- client.with_socket(port: 42_070, active: False)

  client.send_request(
    socket,
    req: "GET / HTTP/1.1\r\nHost: localhost:42070\r\n\r\n",
    chunks: 3,
    interval: 10,
  )

  let raw_resp = <<
    "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 13\r\n\r\nHello, world!",
  >>

  let assert Ok(resp) = tcp.receive(socket, 0)
  assert resp == raw_resp
}
