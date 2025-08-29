// TODO: compression

import ewe/internal/exception
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import glisten/socket
import glisten/socket/options.{ActiveMode, Once}
import glisten/transport
import gramps/websocket as ws

pub type ExitReason {
  Normal
  Abnormal(reason: String)
}

pub type Next {
  Continue
  Stop(ExitReason)
}

pub type State {
  // TODO: user state
  State(conn: WebsocketConnection, buffer: BitArray)
}

pub type WebsocketConnection {
  WebsocketConnection(transport: transport.Transport, socket: socket.Socket)
}

pub type ValidGlistenMessage {
  Packet(BitArray)
  Close
}

pub type GlistenMessage {
  Valid(ValidGlistenMessage)
  Invalid
}

fn select_valid_record(
  selector: process.Selector(GlistenMessage),
  binary_atom: String,
) -> process.Selector(GlistenMessage) {
  process.select_record(selector, atom.create(binary_atom), 2, fn(record) {
    decode.run(record, {
      use data <- decode.field(2, decode.bit_array)
      decode.success(Valid(Packet(data)))
    })
    |> result.unwrap(Invalid)
  })
}

fn glisten_selector() {
  process.new_selector()
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L121
  |> select_valid_record("tcp")
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L129
  |> select_valid_record("ssl")
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L140
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Valid(Close) })
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L137
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Valid(Close) })
}

const malformed_message_error = "Received malformed message"

pub fn start(
  transport: transport.Transport,
  socket: socket.Socket,
  handler: fn(ws.Frame) -> Next,
) {
  actor.new_with_initialiser(1000, fn(subject) {
    let conn = WebsocketConnection(transport, socket)
    actor.initialised(State(conn, <<>>))
    |> actor.selecting(glisten_selector())
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    case msg {
      Valid(Packet(data)) ->
        handle_valid_packet(state, data, transport, socket, handler)
      Valid(Close) -> actor.stop()
      Invalid -> actor.stop_abnormal(malformed_message_error)
    }
  })
  |> actor.start()
  |> result.map(after_start(_, transport, socket))
}

fn handle_valid_packet(
  state: State,
  data: BitArray,
  transport: transport.Transport,
  socket: socket.Socket,
  handler: fn(ws.Frame) -> Next,
) -> actor.Next(State, GlistenMessage) {
  let #(frames, rest) =
    ws.decode_many_frames(<<state.buffer:bits, data:bits>>, None, [])

  // second and third arguments are for accumulation
  let next =
    ws.aggregate_frames(frames, None, [])
    |> result.map(loop_by_frames(_, transport, socket, handler, Continue))

  case next {
    Ok(Continue) -> {
      set_socket_active_once(transport, socket)
      actor.continue(State(..state, buffer: rest))
    }
    Ok(Stop(Normal)) -> actor.stop()
    Ok(Stop(Abnormal(reason))) -> actor.stop_abnormal(reason)
    Error(Nil) -> actor.stop_abnormal(malformed_message_error)
  }
}

fn loop_by_frames(
  frames: List(ws.Frame),
  transport: transport.Transport,
  socket: socket.Socket,
  handler: fn(ws.Frame) -> Next,
  next: Next,
) {
  case frames, next {
    // Early termination cases
    _, Stop(Normal) -> Stop(Normal)
    _, Stop(Abnormal(reason)) -> Stop(Abnormal(reason))

    // No more frames - finish
    [], next -> next

    // Control frames
    [ws.Control(ws.PingFrame(payload))], Continue -> {
      let sent =
        transport.send(transport, socket, ws.encode_pong_frame(payload, None))

      case sent {
        Ok(Nil) -> Continue
        Error(_) -> Stop(Abnormal("Failed to send PONG frame"))
      }
    }
    [ws.Control(ws.CloseFrame(reason))], Continue -> {
      let _ =
        transport.send(transport, socket, ws.encode_close_frame(reason, None))

      Stop(Normal)
    }

    [frame, ..rest], Continue -> {
      case exception.rescue(fn() { handler(frame) }) {
        Ok(Continue) ->
          loop_by_frames(rest, transport, socket, handler, Continue)
        Ok(stop) -> stop
        Error(_) -> Stop(Abnormal("Crash in websocket handler"))
      }
    }
  }
}

// Assigning started actor as the new socket's controlling process
fn after_start(
  started: actor.Started(process.Subject(GlistenMessage)),
  transport: transport.Transport,
  socket: socket.Socket,
) -> process.Pid {
  let assert Ok(pid) = process.subject_owner(started.data)
  let _ = transport.controlling_process(transport, socket, pid)

  set_socket_active_once(transport, socket)

  pid
}

// Controlled message delivery pattern (to receive exactly one message before reverting to passive mode)
fn set_socket_active_once(
  transport: transport.Transport,
  socket: socket.Socket,
) -> Nil {
  let _ = transport.set_opts(transport, socket, [ActiveMode(Once)])

  Nil
}
