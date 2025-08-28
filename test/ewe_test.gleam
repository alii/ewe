// TODO: Add more PROPER tests

import client/tcp as client
import ewe
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleeunit
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn echo_server(port: Int) {
  ewe.new(fn(req) {
    let resp = {
      use req <- result.try(
        response.new(400)
        |> response.set_body(bytes_tree.new())
        |> result.replace_error(ewe.read_body(req, 1024), _),
      )

      response.new(200)
      |> response.set_body(bytes_tree.from_bit_array(req.body))
      |> Ok
    }

    result.unwrap_both(resp)
  })
  |> ewe.with_port(port)
  |> ewe.bind_all()
  |> ewe.with_ipv6()
}

pub fn chunked_body_test() {
  echo_server(42_069) |> ewe.start()

  let req =
    "GET / HTTP/1.1\r\n"
    <> "Host: localhost:42069\r\n"
    <> "Transfer-Encoding: chunked\r\n\r\n"
    <> "D\r\n"
    <> "Hello, world!\r\n"
    <> "D\r\n"
    <> " How are you?\r\n"
    <> "0\r\n\r\n"

  use socket <- client.with_socket(port: 42_069, active: False)
  let _ = tcp.send(socket, bytes_tree.from_string(req))

  let assert Ok(<<
    "HTTP/1.1 200 OK\r\ncontent-length: 26\r\nconnection: keep-alive\r\n\r\nHello, world! How are you?",
  >>) = tcp.receive(socket, 0)

  Nil
}

pub fn request_chunked_test() {
  echo_server(42_070) |> ewe.start()

  let part1 = "GET / HTTP/1.1\r\n"
  let part2 = "Host: localhost:42069\r\n"
  let part3 = "Transfer-Encoding: chunked\r\n\r\n"
  let part4 = "D\r\n"
  let part5 = "Hello, world!\r\n"
  let part6 = "D\r\n"
  let part7 = " How are you?\r\n"
  let part8 = "0\r\n\r\n"

  use socket <- client.with_socket(port: 42_070, active: False)
  let _ = tcp.send(socket, bytes_tree.from_string(part1))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part2))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part3))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part4))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part5))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part6))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part7))
  process.sleep(50)
  let _ = tcp.send(socket, bytes_tree.from_string(part8))
  process.sleep(50)

  let assert Ok(<<
    "HTTP/1.1 200 OK\r\ncontent-length: 26\r\nconnection: keep-alive\r\n\r\nHello, world! How are you?",
  >>) = tcp.receive(socket, 0)

  Nil
}

pub fn connection_keep_alive_test() {
  echo_server(42_071) |> ewe.start()

  let req = "GET / HTTP/1.1\r\n" <> "Host: localhost:42069\r\n"

  let normal = req <> "Content-Length: 9\r\n\r\nPing Pong"

  let chunked =
    req
    <> "Transfer-Encoding: chunked\r\n\r\n"
    <> "D\r\n"
    <> "Hello, world!\r\n"
    <> "D\r\n"
    <> " How are you?\r\n"
    <> "0\r\n\r\n"

  use socket <- client.with_socket(port: 42_069, active: False)
  let _ = tcp.send(socket, bytes_tree.from_string(normal))

  let assert Ok(<<
    "HTTP/1.1 200 OK\r\ncontent-length: 9\r\nconnection: keep-alive\r\n\r\nPing Pong",
  >>) = tcp.receive(socket, 0)

  let _ = tcp.send(socket, bytes_tree.from_string(chunked))

  let assert Ok(<<
    "HTTP/1.1 200 OK\r\ncontent-length: 26\r\nconnection: keep-alive\r\n\r\nHello, world! How are you?",
  >>) = tcp.receive(socket, 0)

  Nil
}

pub fn random_port_and_rescue_test() {
  let name = process.new_name("ewe_server_info")

  let supervisor = supervisor.new(supervisor.OneForOne)

  let assert Ok(_) =
    ewe.new(fn(_req) { panic as "test" })
    |> ewe.with_name(name)
    |> ewe.with_random_port()
    |> ewe.supervised()
    |> supervisor.add(supervisor, _)
    |> supervisor.start()

  let assert Ok(server_info) = ewe.get_server_info(name)

  let assert Ok(req) =
    request.to(
      { server_info.scheme |> http.scheme_to_string }
      <> "://"
      <> server_info.ip_address |> ewe.ip_address_to_string
      <> ":"
      <> server_info.port |> int.to_string,
    )

  let assert Ok(resp) = httpc.send(req)
  echo resp

  Nil
}
