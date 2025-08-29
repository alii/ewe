import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import glisten/socket
import glisten/socket/options
import glisten/transport

pub type WebsocketConnection {
  WebsocketConnection(transport: transport.Transport, socket: socket.Socket)
}

pub type GlistenMessage {
  Packet(BitArray)
  Close
}

fn glisten_selector() {
  process.new_selector()
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L121
  |> process.select_record(atom.create("tcp"), 2, fn(record) {
    decode.run(record, {
      use data <- decode.field(2, decode.bit_array)
      decode.success(Packet(data))
    })
    |> result.unwrap(Packet(<<>>))
  })
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L129
  |> process.select_record(atom.create("ssl"), 2, fn(record) {
    decode.run(record, {
      use data <- decode.field(2, decode.bit_array)
      decode.success(Packet(data))
    })
    |> result.unwrap(Packet(<<>>))
  })
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L140
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Close })
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L137
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Close })
}

pub fn start(transport: transport.Transport, socket: socket.Socket) {
  actor.new_with_initialiser(1000, fn(subject) {
    actor.initialised(<<>>)
    |> actor.selecting(glisten_selector())
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(buffer, msg) {
    echo msg

    actor.continue(buffer)
  })
  |> actor.start()
  |> result.map(fn(started) {
    // NOTE: assigning this actor as the new socket's controlling process
    let assert Ok(pid) = process.subject_owner(started.data)
    transport.controlling_process(transport, socket, pid)

    // controlled message delivery pattern (to receive exactly one message before reverting to passive mode)
    transport.set_opts(transport, socket, [options.ActiveMode(options.Once)])

    pid
  })
}
