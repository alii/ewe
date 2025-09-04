// TODO: fill http tests

import client/tcp as client
import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/string
import glisten/tcp
import server

pub fn basic_test() {
  let socket_address = server.start(server.hi())

  let ip = ewe.ip_address_to_string(socket_address.ip)
  let port = int.to_string(socket_address.port)

  let assert Ok(req) = request.to("http://" <> ip <> ":" <> port <> "/")

  let assert Ok(resp) = httpc.send(req)

  echo resp

  assert resp.status == 200
  assert resp.body == "hi"
  assert response.get_header(resp, "content-type")
    == Ok("text/plain; charset=utf-8")
  assert response.get_header(resp, "content-length") == Ok("2")
}

pub fn chunked_body_test() {
  let socket_address = server.start(server.echoer())

  let ip = ewe.ip_address_to_string(socket_address.ip)
  let port = int.to_string(socket_address.port)

  let assert Ok(req) = request.to("http://" <> ip <> ":" <> port <> "/")
  let req =
    request.set_header(req, "Transfer-Encoding", "chunked")
    |> request.set_method(http.Post)
    |> request.set_header("Host", "localhost:" <> port)
    |> request.set_header("Trailer", "Server-Timing")
    |> request.set_header("Content-Type", "text/plain; charset=utf-8")
    |> request.set_body(
      "8\r\n"
      <> "Mozilla \r\n"
      <> "11\r\n"
      <> "Developer Network\r\n"
      <> "0\r\n"
      <> "Server-Timing: total;dur=1000\r\n"
      <> "\r\n",
    )

  let assert Ok(resp) = httpc.send(req)

  assert resp.status == 200
  assert resp.body == "Mozilla Developer Network"
  assert response.get_header(resp, "content-type")
    == Ok("text/plain; charset=utf-8")
  assert response.get_header(resp, "content-length") == Ok("25")
}

pub fn chunked_body_partial_test() {
  let socket_address = server.start(server.echoer())

  let req =
    "POST /echo HTTP/1.1\r\n"
    <> "Host: localhost:"
    <> int.to_string(socket_address.port)
    <> "\r\n"
    <> "Content-Type: text/plain; charset=utf-8\r\n"
    <> "Transfer-Encoding: chunked\r\n\r\n"

  let chunk1 = "D\r\n" <> "Hello, world!\r\n"
  let chunk2 = "1\r\n"
  let chunk3 = "#\r\n"
  let chunk4 = "0\r\n"

  use socket <- client.with_socket(socket_address.port, active: False)

  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(req))
  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(chunk1))
  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(chunk2))
  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(chunk3))
  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(chunk4))

  let assert Ok(resp) = tcp.receive(socket, 0)
  let assert Ok(Nil) = tcp.close(socket)

  let assert Ok(resp) = bit_array.to_string(resp)
  let assert [_, body] = string.split(resp, "\r\n\r\n")
  assert body == "Hello, world!#"
}
