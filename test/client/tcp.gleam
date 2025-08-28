import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/charlist
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
