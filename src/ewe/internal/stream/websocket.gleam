// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import logging

import websocks

import glisten/socket.{type Socket, type SocketReason}
import glisten/socket/options.{ActiveMode, Count}
import glisten/transport.{type Transport}

import ewe/internal/exception

// -----------------------------------------------------------------------------
// PUBLIC TYPES
// -----------------------------------------------------------------------------

// Represents a WebSocket connection
pub type WebsocketConnection {
  WebsocketConnection(
    transport: Transport,
    socket: Socket,
    context: websocks.Context,
  )
}

// Messages that can be sent to or received from the WebSocket
pub type WebsocketMessage(user_message) {
  Frame(websocks.Frame)
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
  WebsocketState(user_state: user_state, context: websocks.Context)
}

// Type alias for actor next steps
type ActorNext(user_state, user_message) =
  actor.Next(WebsocketState(user_state), InternalMessage(user_message))

// Internal messages used by the WebSocket actor
type InternalMessage(user_message) {
  Packet(BitArray)
  Close
  TcpPassive
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

// /// Gets the deflate context from the compression option
// fn get_deflate(
//   compression: Option(compression.Compression),
// ) -> Option(compression.Context) {
//   option.map(compression, fn(compression) { compression.deflate })
// }

// /// Gets the inflate context from the compression option
// fn get_inflate(
//   compression: Option(compression.Compression),
// ) -> Option(compression.Context) {
//   option.map(compression, fn(compression) { compression.inflate })
// }

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
fn create_socket_selector() -> Selector(InternalMessage(user_message)) {
  process.new_selector()
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L121
  |> select_valid_record("tcp")
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L129
  |> select_valid_record("ssl")
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L140
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) { Close })
  // https://github.com/rawhat/glisten/blob/master/src/glisten/internal/handler.gleam#L137
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) { Close })
  |> process.select_record(atom.create("tcp_passive"), 1, fn(_) { TcpPassive })
}

/// Maps user selector to internal message
fn user_selector(
  selector: Option(Selector(user_message)),
) -> Option(Selector(InternalMessage(user_message))) {
  option.map(selector, fn(selector) { process.map_selector(selector, User) })
}

// -----------------------------------------------------------------------------
// SOCKET UTILITIES
// -----------------------------------------------------------------------------

const socket_active_count = 100

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
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let context_takeovers = websocks.get_context_takeovers(extensions)
    let compression = case permessage_deflate {
      True -> Some(context_takeovers)
      False -> None
    }
    let context = websocks.create_context(compression)

    let #(user_state, user_selector) =
      WebsocketConnection(transport, socket, context)
      |> on_init(process.new_selector())

    let selector =
      process.map_selector(user_selector, User)
      |> process.merge_selector(create_socket_selector())

    WebsocketState(user_state:, context:)
    |> actor.initialised()
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, msg) {
    case msg {
      Packet(data) ->
        handle_valid_packet(transport, socket, state, data, handler, on_close)
      User(user_message) ->
        handle_user_message(
          transport,
          socket,
          state,
          user_message,
          handler,
          on_close,
        )
      Close -> {
        let conn = WebsocketConnection(transport, socket, state.context)
        handle_close(on_close, state, conn, None)
      }
      Invalid -> {
        let conn = WebsocketConnection(transport, socket, state.context)
        handle_close(on_close, state, conn, Some(malformed))
      }
      TcpPassive -> {
        let _ =
          transport.set_opts(transport, socket, [
            ActiveMode(Count(socket_active_count)),
          ])
        actor.continue(state)
      }
    }
  })
  |> actor.start()
  |> result.map(after_start(_, transport, socket))
}

/// Sends a frame to the WebSocket
pub fn send_frame(
  encoder: fn(BitArray, websocks.Context, Option(BitArray)) -> BitArray,
  transport: Transport,
  socket: Socket,
  context: websocks.Context,
  payload: BitArray,
) -> Result(Nil, SocketReason) {
  let frame =
    exception.rescue(fn() {
      encoder(payload, context, option.None)
      |> bytes_tree.from_bit_array()
      |> transport.send(transport, socket, _)
    })

  case frame {
    Ok(frame) -> frame
    Error(reason) -> {
      logging.log(
        logging.Error,
        "Frame should be sent from the WebSocket connection, but was sent from different process: "
          <> string.inspect(reason),
      )
      panic as non_owning_process
    }
  }
}

// -----------------------------------------------------------------------------
// MESSAGE HANDLING
// -----------------------------------------------------------------------------

/// Handles incoming packet data, decoding frames and processing them
fn handle_valid_packet(
  transport: Transport,
  socket: Socket,
  state: WebsocketState(user_state),
  data: BitArray,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) -> ActorNext(user_state, user_message) {
  let decoded = websocks.decode_many_frames(data, state.context)

  // NOTE: I was doing that before
  // let #(data_frames, control_frames) = separate_frames(frames, [], [])

  // let control_result = case control_frames {
  //   [] -> Continue(state.user_state, None)
  //   _ ->
  //     loop_by_frames(
  //       control_frames,
  //       conn,
  //       handler,
  //       Continue(state.user_state, None),
  //     )
  // }

  case decoded {
    Ok(#(decoded_frames, context)) -> {
      case websocks.resolve_fragments(decoded_frames, context) {
        Ok(#(resolved_frames, context)) -> {
          let conn = WebsocketConnection(transport, socket, context)
          let next =
            handle_frames(
              resolved_frames,
              conn,
              handler,
              Continue(state.user_state, None),
            )

          case next {
            Continue(user_state, selector) -> {
              let next = actor.continue(WebsocketState(user_state:, context:))

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
        Error(violation) -> {
          echo violation as "violation during frame resolving"
          let conn = WebsocketConnection(transport, socket, context)
          handle_close(on_close, state, conn, Some(malformed))
        }
      }
    }
    Error(Nil) -> {
      let conn = WebsocketConnection(transport, socket, state.context)
      handle_close(on_close, state, conn, Some(malformed))
    }
  }
}

/// Separates frames into data and control frames
// fn separate_frames(
//   frames: List(websocket.ParsedFrame),
//   data_frames: List(websocket.ParsedFrame),
//   control_frames: List(websocket.Frame),
// ) -> #(List(websocket.ParsedFrame), List(websocket.Frame)) {
//   case frames {
//     [] -> #(list.reverse(data_frames), list.reverse(control_frames))
//     [websocket.Complete(websocket.Control(control_frame)), ..rest] ->
//       separate_frames(rest, data_frames, [
//         websocket.Control(control_frame),
//         ..control_frames
//       ])
//     [data_frame, ..rest] ->
//       separate_frames(rest, [data_frame, ..data_frames], control_frames)
//   }
// }

/// Processes a list of frames sequentially
fn handle_frames(
  frames: List(websocks.Frame),
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
    [websocks.Ping(payload), ..rest], Continue(user_state, _) -> {
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
              websocks.encode_pong_frame(payload, None)
                |> bytes_tree.from_bit_array(),
            )

          case sent {
            Ok(Nil) ->
              handle_frames(rest, conn, handler, Continue(user_state, None))
            Error(_) -> AbnormalStop(failed_pong)
          }
        }
      }
    }
    [websocks.Close(reason), ..], Continue(..) -> {
      let _ =
        transport.send(
          conn.transport,
          conn.socket,
          websocks.encode_close_frame(reason, None)
            |> bytes_tree.from_bit_array(),
        )

      NormalStop
    }

    // Data frames
    [frame, ..rest], Continue(user_state, selector) -> {
      let call =
        exception.rescue(fn() { handler(conn, user_state, Frame(frame)) })

      case call {
        Ok(Continue(user_state, new_selector)) -> {
          let next_selector =
            user_selector(new_selector)
            |> option.or(selector)
            |> option.map(process.merge_selector(create_socket_selector(), _))

          handle_frames(
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
  transport: Transport,
  socket: Socket,
  state: WebsocketState(user_state),
  user_message: user_message,
  handler: Handler(user_state, user_message),
  on_close: OnClose(user_state),
) -> ActorNext(user_state, user_message) {
  let conn = WebsocketConnection(transport, socket, state.context)
  let call =
    exception.rescue(fn() {
      handler(conn, state.user_state, UserMessage(user_message))
    })

  case call {
    Ok(Continue(new_user_state, new_selector)) -> {
      let next_selector =
        user_selector(new_selector)
        |> option.map(process.merge_selector(create_socket_selector(), _))

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
  websocks.close_context(state.context)
  on_close(conn, state.user_state)

  case abnormal_reason {
    Some(reason) -> {
      logging.log(
        logging.Error,
        "WebSocket connection closed abnormally: " <> reason,
      )
      actor.stop_abnormal(reason)
    }
    None -> actor.stop()
  }
}

/// Maps actor's starting value to Nil
fn after_start(
  started: actor.Started(Subject(InternalMessage(user_message))),
  transport: Transport,
  socket: Socket,
) -> actor.Started(Nil) {
  let _ =
    transport.set_opts(transport, socket, [
      ActiveMode(Count(socket_active_count)),
    ])

  actor.Started(..started, data: Nil)
}
