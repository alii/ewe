import client/tcp as client
import ewe
import gleam/dict
import gleam/http/request
import gleam/httpc
import gleeunit
import glisten/tcp
import internal/parser

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn simple_headers_parsing_test() {
  let assert Error(parser.Incomplete) =
    <<"foo: bar\r\n">>
    |> parser.parse_header(dict.new())

  let assert Error(parser.Invalid) =
    <<"foo : bar\r\n">>
    |> parser.parse_header(dict.new())

  let assert Error(parser.MultiLineHeaderUnsupported) =
    <<"foo: bar\r\n\tbaz\r\n\r\n">>
    |> parser.parse_header(dict.new())

  let assert Ok(parser.Parsed(headers, _)) =
    <<"foo:   bar       \r\n\r\n">>
    |> parser.parse_header(dict.new())
  assert dict.to_list(headers) == [#("foo", "bar")]

  let assert Ok(parser.Parsed(headers, _)) =
    <<"foo: bar\r\nContent-Length: 13\r\n\r\n">>
    |> parser.parse_header(dict.new())
  assert dict.to_list(headers) == [#("content-length", "13"), #("foo", "bar")]

  let assert Ok(parser.Parsed(headers, _)) =
    <<"foo: bar\r\nfoo: baz\r\ncontent-length: 13\r\n\r\n">>
    |> parser.parse_header(dict.new())
  assert dict.to_list(headers)
    == [#("content-length", "13"), #("foo", "bar, baz")]
}

pub fn with_tcp_sockets_test() {
  let assert Ok(_started) = ewe.start(port: 42_069)

  use socket <- client.with_socket(port: 42_069, active: False)

  client.send_request(
    socket,
    req: "GET / HTTP/1.1\r\nContent-Length: 0\r\nFoo:   Bar   \r\nHost: localhost:42069\r\n\r\n",
    chunks: 3,
    interval: 10,
  )

  let assert Ok(resp) = tcp.receive(socket, 0)
  assert resp
    == <<"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!">>

  use socket <- client.with_socket(port: 42_069, active: False)

  client.send_request(
    socket,
    req: "GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nHost: localhost:42069\r\n\r\nB\r\nFirst chunk\r\n16\r\nSecond chunk is longer\r\n7\r\nThird!!\r\n27\r\nThis is the fourth chunk with more data\r\n5\r\nShort\r\n55\r\nThis is a really long chunk that contains quite a bit more text to test larger chunks\r\n2\r\nOK\r\n0\r\n\r\n",
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
