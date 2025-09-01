import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/function
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gramps/websocket/compression

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
  State(
    user_state: user_state,
    buffer: BitArray,
    permessage_deflate: Option(compression.Compression),
  )
}

pub type WebsocketConnection {
  WebsocketConnection(
    transport: transport.Transport,
    socket: socket.Socket,
    deflate: Option(compression.Context),
  )
}

pub type HandlerMessage(user_message) {
  Frame(ws.Frame)
  UserMessage(user_message)
}

type ValidMessage {
  Packet(BitArray)
  Close
}

type Message(user_message) {
  Valid(ValidMessage)
  User(user_message)
  Invalid
}

fn select_valid_record(
  selector: process.Selector(Message(user_message)),
  binary_atom: String,
) -> process.Selector(Message(user_message)) {
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

fn get_deflate(
  compression: Option(compression.Compression),
) -> Option(compression.Context) {
  option.map(compression, fn(compression) { compression.deflate })
}

fn get_inflate(
  compression: Option(compression.Compression),
) -> Option(compression.Context) {
  option.map(compression, fn(compression) { compression.inflate })
}

fn close_compression(
  compression: Option(compression.Compression),
) -> Option(Nil) {
  option.map(compression, fn(compression) {
    compression.close(compression.deflate)
    compression.close(compression.inflate)
  })
}

pub fn start(
  transport: transport.Transport,
  socket: socket.Socket,
  on_init: fn(WebsocketConnection, process.Selector(user_message)) ->
    #(user_state, process.Selector(user_message)),
  handler: fn(WebsocketConnection, user_state, HandlerMessage(user_message)) ->
    Next(user_state),
  extensions: List(String),
  permessage_deflate: Bool,
) -> Result(process.Selector(process.Down), actor.StartError) {
  let takeovers = ws.get_context_takeovers(extensions)
  let compression = case permessage_deflate {
    True -> Some(compression.init(takeovers))
    False -> None
  }

  actor.new_with_initialiser(1000, fn(subject) {
    let conn = WebsocketConnection(transport, socket, get_deflate(compression))

    let #(user_state, user_selector) = on_init(conn, process.new_selector())

    let selector =
      process.map_selector(user_selector, User)
      |> process.merge_selector(glisten_selector())

    let ws_state = State(user_state, <<>>, compression)

    actor.initialised(ws_state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    let conn =
      WebsocketConnection(
        transport,
        socket,
        get_deflate(state.permessage_deflate),
      )

    case msg {
      Valid(Packet(data)) -> handle_valid_packet(state, conn, data, handler)
      Valid(Close) -> {
        close_compression(state.permessage_deflate)
        actor.stop()
      }
      User(user_message) ->
        handle_user_message(state, conn, user_message, handler)
      Invalid -> {
        close_compression(state.permessage_deflate)
        actor.stop_abnormal(malformed_message_error)
      }
    }
  })
  |> actor.start()
  |> result.map(after_start(_, transport, socket))
}

fn handle_valid_packet(
  state: State(user_state),
  conn: WebsocketConnection,
  data: BitArray,
  handler: fn(WebsocketConnection, user_state, HandlerMessage(user_message)) ->
    Next(user_state),
) -> actor.Next(State(user_state), Message(user_message)) {
  let buffer = <<state.buffer:bits, data:bits>>

  let #(frames, rest) =
    ws.decode_many_frames(buffer, get_inflate(state.permessage_deflate), [])

  // second and third arguments are for accumulation
  let next =
    ws.aggregate_frames(frames, None, [])
    // |> echo as "aggregated frames:"
    |> result.map(loop_by_frames(_, conn, handler, Continue(state.user_state)))
  // |> echo as "`next` after looping frames:"

  case next {
    Ok(Continue(new_user_state)) -> {
      set_socket_active_once(conn.transport, conn.socket)
      actor.continue(State(..state, buffer: rest, user_state: new_user_state))
    }
    Ok(Stop(Normal)) -> {
      close_compression(state.permessage_deflate)
      actor.stop()
    }
    Ok(Stop(Abnormal(reason))) -> {
      close_compression(state.permessage_deflate)
      actor.stop_abnormal(reason)
    }
    Error(Nil) -> {
      close_compression(state.permessage_deflate)
      actor.stop_abnormal(malformed_message_error)
    }
  }
}

fn loop_by_frames(
  frames: List(ws.Frame),
  conn: WebsocketConnection,
  handler: fn(WebsocketConnection, user_state, HandlerMessage(user_message)) ->
    Next(user_state),
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
      case exception.rescue(fn() { handler(conn, user_state, Frame(frame)) }) {
        Ok(Continue(new_user_state)) ->
          loop_by_frames(rest, conn, handler, Continue(new_user_state))
        Ok(stop) -> stop
        Error(_) -> Stop(Abnormal("Crash in websocket handler"))
      }
    }
  }
}

fn handle_user_message(
  state: State(user_state),
  conn: WebsocketConnection,
  user_message: user_message,
  handler: fn(WebsocketConnection, user_state, HandlerMessage(user_message)) ->
    Next(user_state),
) -> actor.Next(State(user_state), Message(user_message)) {
  let call =
    exception.rescue(fn() {
      handler(conn, state.user_state, UserMessage(user_message))
    })

  case call {
    Ok(Continue(new_user_state)) ->
      actor.continue(State(..state, user_state: new_user_state))
    Ok(Stop(Normal)) -> {
      close_compression(state.permessage_deflate)
      actor.stop()
    }
    Ok(Stop(Abnormal(reason))) -> {
      close_compression(state.permessage_deflate)
      actor.stop_abnormal(reason)
    }
    Error(_) -> {
      close_compression(state.permessage_deflate)
      actor.stop_abnormal("Crash in websocket handler")
    }
  }
}

fn after_start(
  started: actor.Started(process.Subject(Message(user_message))),
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

pub fn send_frame(
  encoder: fn(data, Option(compression.Context), Option(BitArray)) ->
    bytes_tree.BytesTree,
  transport: transport.Transport,
  socket: socket.Socket,
  deflate: Option(compression.Context),
  data: data,
) {
  let sent =
    exception.rescue(fn() {
      encoder(data, deflate, option.None)
      |> transport.send(transport, socket, _)
    })

  case sent {
    Ok(result) -> result
    Error(_) -> panic as "Sending WebSocket message from non-owning process"
  }
}

// Controlled message delivery pattern (to receive exactly one message before reverting to passive mode)
fn set_socket_active_once(
  transport: transport.Transport,
  socket: socket.Socket,
) -> Nil {
  let _ = transport.set_opts(transport, socket, [ActiveMode(Once)])

  Nil
}
