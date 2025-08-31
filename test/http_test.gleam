// TODO: fill http tests

import client/tcp as client
import ewe
import gleam/bytes_tree
import gleam/http/response
import glisten/tcp

pub fn chunked_test() {
  let _ =
    ewe.new(fn(req) {
      case ewe.read_body(req, 1024) {
        Ok(req) -> {
          echo req.headers

          response.new(200) |> ewe.text("ok")
        }
        Error(_) -> response.new(500) |> ewe.empty()
      }
    })
    |> ewe.with_port(8080)
    |> ewe.start()

  let req =
    "GET / HTTP/1.1\r\n"
    <> "Host: localhost:8080\r\n"
    <> "Content-Type: text/plain\r\n"
    <> "Transfer-Encoding: chunked\r\n"
    <> "Trailer: Server-Timing\r\n"
    <> "\r\n"
    <> "7\r\n"
    <> "Mozilla\r\n"
    <> "11\r\n"
    <> "Developer Network\r\n"
    <> "0\r\n"
    <> "Server-Timing: total;dur=1000\r\n"
    <> "\r\n"

  let req = bytes_tree.from_string(req)

  use socket <- client.with_socket(8080, active: False)

  let assert Ok(Nil) = tcp.send(socket, req)

  let assert Ok(resp) = tcp.receive(socket, 0)

  echo resp

  Nil
}
