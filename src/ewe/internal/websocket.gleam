// TODO: compression

import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/function
import gleam/option.{None}
import gleam/otp/actor
import gleam/result

import glisten
import glisten/socket
import glisten/socket/options.{ActiveMode, Once}
import glisten/transport

import gramps/websocket as ws

import ewe/internal/exception

pub type ExitReason {
  Normal
  Abnormal(reason: String)
}

pub type Next(user_state) {
  Continue(user_state)
  Stop(ExitReason)
}

type State(user_state) {
  // TODO: user state
  State(conn: WebsocketConnection, user_state: user_state, buffer: BitArray)
}

pub type WebsocketConnection {
  WebsocketConnection(transport: transport.Transport, socket: socket.Socket)
}

type ValidGlistenMessage {
  Packet(BitArray)
  Close
}

type GlistenMessage {
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
  on_init: fn(WebsocketConnection) -> user_state,
  handler: fn(WebsocketConnection, user_state, ws.Frame) -> Next(user_state),
) -> Result(process.Selector(process.Down), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let conn = WebsocketConnection(transport, socket)

    let user_state = on_init(conn)

    actor.initialised(State(conn, user_state, <<>>))
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
  state: State(user_state),
  data: BitArray,
  transport: transport.Transport,
  socket: socket.Socket,
  handler: fn(WebsocketConnection, user_state, ws.Frame) -> Next(user_state),
) -> actor.Next(State(user_state), GlistenMessage) {
  let #(frames, rest) =
    ws.decode_many_frames(<<state.buffer:bits, data:bits>>, None, [])

  // second and third arguments are for accumulation
  let next =
    ws.aggregate_frames(frames, None, [])
    // |> echo as "aggregated frames:"
    |> result.map(loop_by_frames(
      _,
      state.conn,
      handler,
      Continue(state.user_state),
    ))
  // |> echo as "`next` after looping frames:"

  case next {
    Ok(Continue(new_user_state)) -> {
      set_socket_active_once(transport, socket)
      actor.continue(State(..state, buffer: rest, user_state: new_user_state))
    }
    Ok(Stop(Normal)) -> actor.stop()
    Ok(Stop(Abnormal(reason))) -> actor.stop_abnormal(reason)
    Error(Nil) -> actor.stop_abnormal(malformed_message_error)
  }
}

fn loop_by_frames(
  frames: List(ws.Frame),
  conn: WebsocketConnection,
  handler: fn(WebsocketConnection, user_state, ws.Frame) -> Next(user_state),
  next: Next(user_state),
) -> Next(user_state) {
  case frames, next {
    // Early termination cases
    _, Stop(Normal) -> Stop(Normal)
    _, Stop(Abnormal(reason)) -> Stop(Abnormal(reason))

    // No more frames - finish
    [], next -> next

    // Control frames
    [ws.Control(ws.PingFrame(payload))], Continue(user_state) -> {
      let sent =
        transport.send(
          conn.transport,
          conn.socket,
          ws.encode_pong_frame(payload, None),
        )

      case sent {
        Ok(Nil) -> Continue(user_state)
        Error(_) -> Stop(Abnormal("Failed to send PONG frame"))
      }
    }
    [ws.Control(ws.CloseFrame(reason))], Continue(_) -> {
      let _ =
        transport.send(
          conn.transport,
          conn.socket,
          ws.encode_close_frame(reason, None),
        )

      Stop(Normal)
    }

    // Data frames
    [frame, ..rest], Continue(user_state) -> {
      case exception.rescue(fn() { handler(conn, user_state, frame) }) {
        Ok(Continue(new_user_state)) ->
          loop_by_frames(rest, conn, handler, Continue(new_user_state))
        Ok(stop) -> stop
        Error(_) -> Stop(Abnormal("Crash in websocket handler"))
      }
    }
  }
}

fn after_start(
  started: actor.Started(process.Subject(GlistenMessage)),
  transport: transport.Transport,
  socket: socket.Socket,
) -> process.Selector(process.Down) {
  // Assigning started actor as the new socket's controlling process
  let assert Ok(pid) = process.subject_owner(started.data)
  let _ = transport.controlling_process(transport, socket, pid)

  set_socket_active_once(transport, socket)

  let selector =
    process.select_specific_monitor(
      process.new_selector(),
      process.monitor(pid),
      function.identity,
    )

  selector
}

pub fn send_binary_frame(
  transport: transport.Transport,
  socket: socket.Socket,
  bits: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  ws.encode_binary_frame(bits, option.None, option.None)
  |> transport.send(transport, socket, _)
}

pub fn send_text_frame(
  transport: transport.Transport,
  socket: socket.Socket,
  text: String,
) -> Result(Nil, glisten.SocketReason) {
  ws.encode_text_frame(text, option.None, option.None)
  |> transport.send(transport, socket, _)
}

// Controlled message delivery pattern (to receive exactly one message before reverting to passive mode)
fn set_socket_active_once(
  transport: transport.Transport,
  socket: socket.Socket,
) -> Nil {
  let _ = transport.set_opts(transport, socket, [ActiveMode(Once)])

  Nil
}
