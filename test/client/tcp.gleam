import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/erlang/process
import gleam/int
import glisten/socket
import glisten/tcp

pub fn with_socket(
  port port: Int,
  active active: Bool,
  callback callback: fn(socket.Socket) -> Nil,
) {
  let assert Ok(socket) =
    tcp_connect(charlist.from_string("localhost"), port, [
      from(atom.create("binary")),
      from(#(atom.create("active"), active)),
    ])

  callback(socket)

  let assert Ok(Nil) = tcp.close(socket)

  Nil
}

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  host: charlist.Charlist,
  port: Int,
  options: List(dynamic.Dynamic),
) -> Result(socket.Socket, Nil)

// https://github.com/rawhat/glisten/blob/master/test/tcp_client.gleam#L13C1-L14C29
@external(erlang, "gleam@function", "identity")
fn from(value: a) -> dynamic.Dynamic

pub fn send_request(
  socket: socket.Socket,
  req request: String,
  chunks amount: Int,
  interval interval: Int,
) -> Nil {
  let request = request |> bytes_tree.from_string
  let total = bytes_tree.byte_size(request)
  let chunk_size = total / amount + 1

  send_chunk(socket, bytes_tree.to_bit_array(request), 0, chunk_size, interval)
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
