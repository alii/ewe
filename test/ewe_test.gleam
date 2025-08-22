import client/tcp as client
import ewe
import gleam/bit_array
import gleam/http/request
import gleam/httpc
import gleam/result
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
    req: "GET / HTTP/1.1\r\nHost: localhost:42069\r\nTransfer-Encoding: chunked\r\ntrailer: etag, Digest\r\n\r\nB\r\nFirst chunk\r\n16\r\nSecond chunk is longer\r\n7\r\nThird!!\r\n27\r\nThis is the fourth chunk with more data\r\n5\r\nShort\r\n55\r\nThis is a really long chunk that contains quite a bit more text to test larger chunks\r\n2\r\nOK\r\n0\r\nETag: \"abc123\"\r\nDigest: sha-256=xyz\r\n\r\n",
    chunks: 10,
    interval: 10,
  )

  let assert Ok(resp) = tcp.receive(socket, 0)
  assert resp
    == <<"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!">>
}

// pub fn with_tcp_too_large_test() {
// let assert Ok(_started) = ewe.start(port: 42_071)

// use socket <- client.with_socket(port: 42_071, active: False)
// client.send_request(
//   socket,
//   req: "GET / HTTP/1.1\r\nHost: localhost:42069\r\nTransfer-Encoding: chunked\r\n\r\nB\r\nFirst chunk\r\n16\r\nSecond chunk is longer\r\n7\r\nThird!!\r\n27\r\nThis is the fourth chunk with more data\r\n5\r\nShort\r\n55\r\nThis is a really long chunk that contains quite a bit more text to test larger chunks\r\n2\r\nOK\r\n0\r\n\r\n",
//   chunks: 10,
//   interval: 10,
// )
// client.send_request(
//   socket,
//   req: "GET / HTTP/1.1\r\n"
//     <> big_text(<<"Content-Type: text/plain\r\n">>, 8192, <<>>),
//   chunks: 1,
//   interval: 10,
// )
// }

pub fn with_http_test() {
  let assert Ok(_started) = ewe.start(port: 42_070)

  let assert Ok(req) = request.to("http://localhost:42070/hello/world")
  let assert Ok(resp) = httpc.send(req)
  assert resp.status == 200
}

fn big_text(part: BitArray, repeat_until: Int, acc: BitArray) -> String {
  case bit_array.byte_size(acc) {
    size if size - repeat_until < 0 ->
      big_text(part, repeat_until, <<acc:bits, part:bits>>)

    _ -> acc |> bit_array.to_string |> result.unwrap("")
  }
}
