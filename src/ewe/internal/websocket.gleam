// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/function
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

import glisten/socket.{type Socket, type SocketReason}
import glisten/socket/options.{ActiveMode, Once}
import glisten/transport.{type Transport}

import gramps/websocket.{type Frame, CloseFrame, PingFrame}
import gramps/websocket/compression

import ewe/internal/exception

// -----------------------------------------------------------------------------
// PUBLIC TYPES
// -----------------------------------------------------------------------------

// Represents a WebSocket connection
pub type WebsocketConnection {
  WebsocketConnection(
    transport: Transport,
    socket: Socket,
    deflate: Option(compression.Context),
  )
}

// Messages that can be sent to or received from the WebSocket
pub type WebsocketMessage(user_message) {
  WebsocketFrame(Frame)
  UserMessage(user_message)
}

// Control flow for WebSocket message handling
pub type WebsocketNext(user_state, user_message) {
  Continue(user_state, Option(Selector(user_message)))
  NormalStop
  AbnormalStop(reason: String)
}

// -----------------------------------------------------------------------------
// INTERNAL TYPES
// -----------------------------------------------------------------------------

// Internal state maintained by the WebSocket actor
type WebsocketState(user_state) {
  WebsocketState(
    user_state: user_state,
    permessage_deflate: Option(compression.Compression),
    buffer: BitArray,
    awaiting_frames: List(websocket.ParsedFrame),
  )
}

// Type alias for actor next steps
type ActorNext(user_state, user_message) =
  actor.Next(WebsocketState(user_state), InternalMessage(user_message))

// Internal messages used by the WebSocket actor
type InternalMessage(user_message) {
  Packet(BitArray)
  Close
  User(user_message)
  Invalid
}

// -----------------------------------------------------------------------------
// CALLBACK TYPE ALIASES
// -----------------------------------------------------------------------------

// Function called when the WebSocket connection is initialized
type OnInit(user_state, user_message) =
  fn(WebsocketConnection, Selector(user_message)) ->
    #(user_state, Selector(user_message))

// Function called to handle incoming WebSocket messages
type Handler(user_state, user_message) =
  fn(WebsocketConnection, user_state, WebsocketMessage(user_message)) ->
    WebsocketNext(user_state, user_message)

// Function called when the WebSocket connection is closed
type OnClose(user_state) =
  fn(WebsocketConnection, user_state) -> Nil

// -----------------------------------------------------------------------------
// CONSTANTS
// -----------------------------------------------------------------------------

const malformed = "Received malformed message"

const crashed = "Crash in websocket handler"

const failed_pong = "Failed to send PONG frame"

const non_owning_process = "Sending WebSocket message from non-owning process"

// -----------------------------------------------------------------------------
// COMPRESSION UTILITIES
// -----------------------------------------------------------------------------

/// Gets the deflate context from the compression option
fn get_deflate(
  compression: Option(compression.Compression),
) -> Option(compression.Context) {
  option.map(compression, fn(compression) { compression.deflate })
}

/// Gets the inflate context from the compression option
fn get_inflate(
  compression: Option(compression.Compression),
) -> Option(compression.Context) {
  option.map(compression, fn(compression) { compression.inflate })
}

// -----------------------------------------------------------------------------
// SELECTOR UTILITIES
// -----------------------------------------------------------------------------

/// Creates a selector for valid TCP/SSL records
fn select_valid_record(
  selector: Selector(InternalMessage(user_message)),
  binary_atom: String,
) -> Selector(InternalMessage(user_message)) {
  process.select_record(selector, atom.create(binary_atom), 2, fn(record) {
    decode.run(record, {
      use data <- decode.field(2, decode.bit_array)
      decode.success(Packet(data))
    })
    |> result.unwrap(Invalid)
  })
}

/// Creates selector for glisten socket events
fn glisten_selector() -> Selector(InternalMessage(user_message)) {
  process.new_selector()
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L121
  |> select_valid_record("tcp")
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L129
  |> select_valid_record("ssl")
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L140
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Close })
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L137
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Close })
}

fn user_selector(
  selector: Option(Selector(user_message)),
) -> Option(Selector(InternalMessage(user_message))) {
  option.map(selector, fn(selector) { process.map_selector(selector, User) })
}

// -----------------------------------------------------------------------------
// SOCKET UTILITIES
// -----------------------------------------------------------------------------

/// Sets socket to active mode for one message delivery
fn set_socket_active_once(transport: Transport, socket: Socket) -> Nil {
  let _ = transport.set_opts(transport, socket, [ActiveMode(Once)])
  Nil
}

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Starts a new WebSocket connection
pub fn start(
  transport: Transport,
  socket: Socket,
  on_init: OnInit(user_state, user_message),
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
  extensions: List(String),
  permessage_deflate: Bool,
) -> Result(Selector(process.Down), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let takeovers = websocket.get_context_takeovers(extensions)
    let deflate = case permessage_deflate {
      True -> Some(compression.init(takeovers))
      False -> None
    }

    let conn = WebsocketConnection(transport, socket, get_deflate(deflate))

    let #(user_state, user_selector) = on_init(conn, process.new_selector())

    let selector =
      process.map_selector(user_selector, User)
      |> process.merge_selector(glisten_selector())

    let ws_state =
      WebsocketState(
        user_state:,
        permessage_deflate: deflate,
        buffer: <<>>,
        awaiting_frames: [],
      )

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
      Packet(data) -> handle_valid_packet(state, conn, data, handler, on_close)
      Close -> handle_close(on_close, state, conn, None)
      User(user_message) ->
        handle_user_message(state, conn, user_message, handler, on_close)
      Invalid -> handle_close(on_close, state, conn, Some(malformed))
    }
  })
  |> actor.start()
  |> result.map(after_start(_, transport, socket))
}

/// Sends a frame to the WebSocket
pub fn send_frame(
  encoder: fn(data, Option(compression.Context), Option(BitArray)) -> BytesTree,
  transport: Transport,
  socket: Socket,
  deflate: Option(compression.Context),
  data: data,
) -> Result(Nil, SocketReason) {
  let frame =
    exception.rescue(fn() {
      encoder(data, deflate, option.None)
      |> transport.send(transport, socket, _)
    })

  case frame {
    Ok(frame) -> frame
    Error(_) -> panic as non_owning_process
  }
}

// -----------------------------------------------------------------------------
// MESSAGE HANDLING
// -----------------------------------------------------------------------------

/// Handles incoming packet data, decoding frames and processing them
fn handle_valid_packet(
  state: WebsocketState(user_state),
  conn: WebsocketConnection,
  data: BitArray,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) -> ActorNext(user_state, user_message) {
  let buffer = <<state.buffer:bits, data:bits>>

  let decoded =
    websocket.decode_many_frames_result(
      buffer,
      get_inflate(state.permessage_deflate),
      [],
    )

  case decoded {
    Ok(#(frames, rest)) ->
      handle_frames_processing(state, conn, frames, rest, handler, on_close)
    Error(websocket.NeedMoreDataAccumulated(parsed, rest)) -> {
      set_socket_active_once(conn.transport, conn.socket)

      actor.continue(
        WebsocketState(
          ..state,
          buffer: rest,
          // NOTE: idk if its correct
          awaiting_frames: list.append(state.awaiting_frames, parsed),
        ),
      )
    }
    Error(websocket.InvalidFrameAccumulated(_parsed)) -> {
      handle_close(on_close, state, conn, Some(malformed))
    }
  }
}

fn handle_frames_processing(
  state: WebsocketState(user_state),
  conn: WebsocketConnection,
  frames: List(websocket.ParsedFrame),
  rest: BitArray,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) {
  let frames = list.append(state.awaiting_frames, frames)

  let #(data_frames, control_frames) = separate_frames(frames, [], [])

  // echo #(data_frames, control_frames)

  let control_result = case control_frames {
    [] -> Continue(state.user_state, None)
    _ ->
      loop_by_frames(
        control_frames,
        conn,
        handler,
        Continue(state.user_state, None),
      )
  }

  case control_result {
    NormalStop -> handle_close(on_close, state, conn, None)
    AbnormalStop(reason) -> handle_close(on_close, state, conn, Some(reason))
    Continue(_, _) -> {
      let aggregated = websocket.aggregate_frames(data_frames, None, [])

      case aggregated {
        Ok([]) -> {
          set_socket_active_once(conn.transport, conn.socket)

          actor.continue(
            WebsocketState(..state, buffer: rest, awaiting_frames: data_frames),
          )
        }
        Ok(data_frames) -> {
          let next =
            loop_by_frames(
              data_frames,
              conn,
              handler,
              Continue(state.user_state, None),
            )

          case next {
            Continue(user_state, selector) -> {
              set_socket_active_once(conn.transport, conn.socket)

              let next =
                actor.continue(
                  WebsocketState(
                    ..state,
                    user_state:,
                    buffer: rest,
                    awaiting_frames: [],
                  ),
                )

              case selector {
                Some(selector) -> actor.with_selector(next, selector)
                None -> next
              }
            }
            NormalStop -> handle_close(on_close, state, conn, None)
            AbnormalStop(reason) ->
              handle_close(on_close, state, conn, Some(reason))
          }
        }
        Error(Nil) -> handle_close(on_close, state, conn, Some(malformed))
      }
    }
  }
}

fn separate_frames(
  frames: List(websocket.ParsedFrame),
  data_frames: List(websocket.ParsedFrame),
  control_frames: List(websocket.Frame),
) -> #(List(websocket.ParsedFrame), List(websocket.Frame)) {
  case frames {
    [] -> #(list.reverse(data_frames), list.reverse(control_frames))
    [websocket.Complete(websocket.Control(control_frame)), ..rest] ->
      separate_frames(rest, data_frames, [
        websocket.Control(control_frame),
        ..control_frames
      ])
    [data_frame, ..rest] ->
      separate_frames(rest, [data_frame, ..data_frames], control_frames)
  }
}

/// Processes a list of frames sequentially
fn loop_by_frames(
  frames: List(Frame),
  conn: WebsocketConnection,
  handler: Handler(user_state, user_message),
  next: WebsocketNext(user_state, InternalMessage(user_message)),
) -> WebsocketNext(user_state, InternalMessage(user_message)) {
  case frames, next {
    // Early termination cases
    _, NormalStop -> NormalStop
    _, AbnormalStop(reason) -> AbnormalStop(reason)

    // No more frames - finish
    [], next -> next

    // Control frames
    [websocket.Control(PingFrame(payload)), ..rest], Continue(user_state, _) -> {
      case bit_array.byte_size(payload) {
        size if size > 125 ->
          AbnormalStop(
            "control frames are only allowed to have payload up to and including 125 octets",
          )
        _ -> {
          let sent =
            transport.send(
              conn.transport,
              conn.socket,
              websocket.encode_pong_frame(payload, None),
            )

          case sent {
            Ok(Nil) ->
              loop_by_frames(rest, conn, handler, Continue(user_state, None))
            Error(_) -> AbnormalStop(failed_pong)
          }
        }
      }
    }
    [websocket.Control(CloseFrame(reason)), ..], Continue(_, _) -> {
      let _ =
        transport.send(
          conn.transport,
          conn.socket,
          websocket.encode_close_frame(reason, None),
        )

      NormalStop
    }

    // NOTE: unsure if its should be here
    [websocket.Continuation(_, _), ..], Continue(_, _) -> {
      AbnormalStop("Unexpected continuation frame")
    }

    // Data frames
    [frame, ..rest], Continue(user_state, selector) -> {
      let call =
        exception.rescue(fn() {
          handler(conn, user_state, WebsocketFrame(frame))
        })

      case call {
        Ok(Continue(user_state, new_selector)) -> {
          let next_selector =
            user_selector(new_selector)
            |> option.or(selector)
            |> option.map(process.merge_selector(glisten_selector(), _))

          loop_by_frames(
            rest,
            conn,
            handler,
            Continue(user_state, next_selector),
          )
        }
        Ok(NormalStop) -> NormalStop
        Ok(AbnormalStop(reason)) -> AbnormalStop(reason)
        Error(_) -> AbnormalStop(crashed)
      }
    }
  }
}

/// Handles user messages sent to the WebSocket
fn handle_user_message(
  state: WebsocketState(user_state),
  conn: WebsocketConnection,
  user_message: user_message,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) -> ActorNext(user_state, user_message) {
  let call =
    exception.rescue(fn() {
      handler(conn, state.user_state, UserMessage(user_message))
    })

  case call {
    Ok(Continue(new_user_state, new_selector)) -> {
      let next_selector =
        user_selector(new_selector)
        |> option.map(process.merge_selector(glisten_selector(), _))

      let next =
        actor.continue(WebsocketState(..state, user_state: new_user_state))

      case next_selector {
        Some(selector) -> actor.with_selector(next, selector)
        None -> next
      }
    }
    Ok(NormalStop) -> handle_close(on_close, state, conn, None)
    Ok(AbnormalStop(reason)) ->
      handle_close(on_close, state, conn, Some(reason))
    Error(_) -> handle_close(on_close, state, conn, Some(crashed))
  }
}

// -----------------------------------------------------------------------------
// CONNECTION MANAGEMENT
// -----------------------------------------------------------------------------

/// Handles WebSocket connection closure
fn handle_close(
  on_close: OnClose(user_state),
  state: WebsocketState(user_state),
  conn: WebsocketConnection,
  abnormal_reason: Option(String),
) -> actor.Next(WebsocketState(user_state), InternalMessage(user_message)) {
  option.map(state.permessage_deflate, fn(compression) {
    compression.close(compression.deflate)
    compression.close(compression.inflate)
  })

  on_close(conn, state.user_state)

  case abnormal_reason {
    Some(reason) -> actor.stop_abnormal(reason)
    None -> actor.stop()
  }
}

/// Sets up monitoring after actor start
fn after_start(
  started: actor.Started(Subject(InternalMessage(user_message))),
  transport: Transport,
  socket: Socket,
) -> Selector(process.Down) {
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
