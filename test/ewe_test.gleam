import client/tcp as client
import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleeunit
import glisten/socket
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn with_tcp_sockets_test() {
  let assert Ok(_started) = ewe.start(port: 42_069)

  run_chunked_request(
    req: "GET / HTTP/1.1\r\nContent-Length: 0\r\nFoo:   Bar   \r\n\r\n",
    chunks_amount: 3,
    wait: 100,
  )
}

pub fn with_http_test() {
  let assert Ok(_started) = ewe.start(port: 42_070)

  let assert Ok(req) = request.to("http://localhost:42070/hello/world")
  let assert Ok(resp) = httpc.send(req)
  echo resp
}

fn run_chunked_request(
  req request: String,
  chunks_amount amount: Int,
  wait wait: Int,
) -> Nil {
  let socket = client.connect(42_069)

  let request = request |> bytes_tree.from_string
  let total = bytes_tree.byte_size(request)
  let chunk_size = total / amount + 1

  send_chunk(socket, bytes_tree.to_bit_array(request), 0, chunk_size, wait)

  let assert Ok(Nil) = tcp.close(socket)

  Nil
}

fn send_chunk(
  socket: socket.Socket,
  request: BitArray,
  starting: Int,
  chunk_size: Int,
  wait: Int,
) {
  let rest = case request {
    <<_:bytes-size(starting), end:bytes>> -> bit_array.byte_size(end)
    _ -> bit_array.byte_size(request)
  }

  let read = int.min(chunk_size, rest)
  let chunk = bit_array.slice(request, starting, read)

  case chunk {
    Ok(chunk) -> {
      case tcp.send(socket, bytes_tree.from_bit_array(chunk)) {
        Ok(Nil) -> {
          process.sleep(wait)
          send_chunk(socket, request, starting + chunk_size, chunk_size, wait)
        }
        Error(error) -> {
          echo error as "stopping chunked request"
          Nil
        }
      }
    }
    Error(_) -> Nil
  }
}
