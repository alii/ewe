import client/tcp as client
import ewe
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleeunit
import glisten/socket
import glisten/tcp

pub fn main() -> Nil {
  gleeunit.main()
}

// NOTE: temporary while exploring glisten capabilities
pub fn slow_request_test() {
  let assert Ok(_started) = ewe.start()

  run_chunked_request(
    req: "GET / HTTP/1.1\r\nContent-Length: 13\r\nFoo:   Bar   \r\n\r\nHello, world!",
    chunks_amount: 1,
    wait: 100,
  )
  run_chunked_request(
    req: "POST / HTTP/1.1\r\n\r\n",
    chunks_amount: 1,
    wait: 100,
  )

  run_chunked_request(
    req: "GEE / HTTP/1.1\r\n\r\n",
    chunks_amount: 1,
    wait: 100,
  )

  run_chunked_request(
    req: "POST / HTTP/2.1\r\n\r\n",
    chunks_amount: 1,
    wait: 100,
  )
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
