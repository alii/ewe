import client/tcp as client
import ewe
import gleam/bytes_tree
import gleam/http/response
import gleam/result
import gleeunit
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn echo_server(port: Int) {
  let assert Ok(_) =
    ewe.new(fn(req) {
      let resp = {
        use req <- result.try(
          response.new(400)
          |> response.set_body(bytes_tree.new())
          |> result.replace_error(ewe.read_body(req), _),
        )

        response.new(200)
        |> response.set_body(bytes_tree.from_bit_array(req.body))
        |> Ok
      }

      result.unwrap_both(resp)
    })
    |> ewe.port(port)
    |> ewe.start()

  Nil
}

pub fn chunked_body_test() {
  echo_server(42_069)

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

  let assert Ok(<<"HTTP/1.1 200 OK\r\n\r\nHello, world! How are you?">>) =
    tcp.receive(socket, 0)

  Nil
}

pub fn request_chunked_test() {
  echo_server(42_070)

  let part1 = "GET / HTTP/1.1\r\n"
  let part2 = "Host: localhost:42069\r\n"
  let part3 = "Transfer-Encoding: chunked\r\n\r\n"
  let part4 = "D\r\n"
  let part5 = "Hello, world!\r\n"
  let part6 = "D\r\n"
  let part7 = " How are you?\r\n"
  let part8 = "0\r\n\r\n"

  use socket <- client.with_socket(port: 42_069, active: False)
  let _ = tcp.send(socket, bytes_tree.from_string(part1))
  let _ = tcp.send(socket, bytes_tree.from_string(part2))
  let _ = tcp.send(socket, bytes_tree.from_string(part3))
  let _ = tcp.send(socket, bytes_tree.from_string(part4))
  let _ = tcp.send(socket, bytes_tree.from_string(part5))
  let _ = tcp.send(socket, bytes_tree.from_string(part6))
  let _ = tcp.send(socket, bytes_tree.from_string(part7))
  let _ = tcp.send(socket, bytes_tree.from_string(part8))

  let assert Ok(<<"HTTP/1.1 200 OK\r\n\r\nHello, world! How are you?">>) =
    tcp.receive(socket, 0)

  Nil
}
