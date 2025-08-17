import gleam/bytes_tree
import gleam/erlang/process
import gleam/option.{None}
import glisten

// NOTE: will be removed once we have a public API
pub fn main() -> Nil {
  let assert Ok(_) = start()

  process.sleep_forever()
}

// No public API for now
pub fn start() {
  // NOTE: state will probably be buffer & parsing state
  glisten.new(fn(_conn) { #(<<>>, None) }, fn(buffer, msg, conn) {
    echo buffer as "buffer before receiving message"
    let assert glisten.Packet(msg) = msg

    let current = <<buffer:bits, msg:bits>>
    echo current as "buffer after receiving message"

    // NOTE: parsing received messages from buffer, if it's ewww then
    // continue until we have a full message ??? Else, we will put the
    // parsed request as argument of handler.

    // And theeeen we can figure out what to do next

    // hard coded response for now
    let _ =
      "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!"
      |> bytes_tree.from_string
      |> glisten.send(conn, _)

    glisten.continue(current)
  })
  |> glisten.bind("0.0.0.0")
  |> glisten.start(42_069)
}
