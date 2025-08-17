import client/tcp as client
import ewe
import gleam/bytes_tree
import gleam/erlang/process
import gleeunit
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

// NOTE: temporary while exploring glisten capabilities
pub fn slow_request_test() {
  let assert Ok(_started) = ewe.start()

  let socket = client.connect(42_069)
  let assert Ok(Nil) = tcp.send(socket, "GET / HTT" |> bytes_tree.from_string)

  process.sleep(100)

  let assert Ok(Nil) =
    tcp.send(socket, "P/1.1\r\n\r\n" |> bytes_tree.from_string)

  let assert Ok(Nil) = tcp.close(socket)

  let socket = client.connect(42_069)

  let assert Ok(Nil) =
    tcp.send(socket, "GET / HTTP/1.1\r\n\r\n" |> bytes_tree.from_string)

  let assert Ok(Nil) = tcp.close(socket)
}
