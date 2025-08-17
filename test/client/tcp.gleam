// https://github.com/rawhat/glisten/blob/master/test/tcp_client.gleam#L13C1-L14C29
// evil in the finest:
// @external(erlang, "gleam@function", "identity")
// fn from(value: a) -> dynamic.Dynamic

import gleam/erlang/atom
import gleam/erlang/charlist
import glisten/socket

pub fn connect(port port: Int) -> socket.Socket {
  let assert Ok(client) =
    tcp_connect(charlist.from_string("localhost"), port, [
      atom.create("binary"),
    ])
  client
}

@external(erlang, "gen_tcp", "connect")
fn tcp_connect(
  host: charlist.Charlist,
  port: Int,
  options: List(atom.Atom),
) -> Result(socket.Socket, Nil)
