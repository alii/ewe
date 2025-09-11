import client/tcp as client
import ewe
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import glisten/socket
import glisten/tcp
import server

pub fn idle_timeout_test() {
  let socket_address = server.start(server.echoer() |> ewe.idle_timeout(1000))

  let _ = ewe.ip_address_to_string(socket_address.ip)
  let port = int.to_string(socket_address.port)

  use socket <- client.with_socket(socket_address.port, active: False)

  let req =
    "GET /echo HTTP/1.1\r\n"
    <> "Host: localhost:"
    <> port
    <> "\r\n"
    <> "Connection: keep-alive\r\n"
    <> "\r\n"

  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(req))
  let assert Ok(_) = tcp.receive(socket, 0)

  process.sleep(500)

  let assert Ok(Nil) = tcp.send(socket, bytes_tree.from_string(req))
  let assert Ok(_) = tcp.receive(socket, 0)

  let assert Error(socket.Timeout) = tcp.receive_timeout(socket, 0, 600)
  let assert Error(socket.Closed) = tcp.receive_timeout(socket, 0, 500)

  Nil
}
