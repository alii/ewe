import client/tcp as client
import ewe
import gleam/http/request
import gleam/httpc
import gleeunit
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn with_tcp_sockets_test() {
  let assert Ok(_started) = ewe.start(port: 42_069)

  use socket <- client.with_socket(port: 42_069, active: False)

  client.send_request(
    socket,
    req: "GET / HTTP/1.1\r\nHost: localhost:42069\r\n\r\n",
    chunks: 3,
    interval: 10,
  )

  let assert Ok(resp) = tcp.receive(socket, 0)
  assert resp
    == <<"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!">>

  use socket <- client.with_socket(port: 42_069, active: False)

  client.send_request(
    socket,
    req: "POST / HTTP/1.1\r\nHost: localhost:42069\r\nContent-Length: 13\r\n\r\nHello, world!",
    chunks: 1,
    interval: 10,
  )

  use socket <- client.with_socket(port: 42_069, active: False)

  client.send_request(
    socket,
    req: "GET / HTTP/1.1\r\nHost: localhost:42069\r\nTransfer-Encoding: chunked\r\n\r\nB\r\nFirst chunk\r\n16\r\nSecond chunk is longer\r\n7\r\nThird!!\r\n27\r\nThis is the fourth chunk with more data\r\n5\r\nShort\r\n55\r\nThis is a really long chunk that contains quite a bit more text to test larger chunks\r\n2\r\nOK\r\n0\r\n\r\n",
    chunks: 10,
    interval: 10,
  )

  let assert Ok(resp) = tcp.receive(socket, 0)
  assert resp
    == <<"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!">>
}

pub fn with_http_test() {
  let assert Ok(_started) = ewe.start(port: 42_070)

  let assert Ok(req) = request.to("http://localhost:42070/hello/world")
  let assert Ok(resp) = httpc.send(req)
  assert resp.status == 200
}
