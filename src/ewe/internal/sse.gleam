import ewe/internal/encoder
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/erlang/process.{type Selector, type Subject}
import gleam/function
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string_tree
import glisten/socket.{type Socket}
import glisten/transport.{type Transport}

pub type SSEConnection {
  SSEConnection(transport: Transport, socket: Socket)
}

pub type SSEEvent {
  SSEEvent(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

pub type SSENext(user_state) {
  Continue(user_state)
  NormalStop
  AbnormalStop(reason: String)
}

pub type SSEMessages(user_message) {
  User(user_message)
  Internal(Internal)
}

pub type Internal {
  SocketClose
  Down
}

fn create_socket_selector(
  user_subject: Subject(user_message),
  internal_subject: Subject(Internal),
) {
  process.new_selector()
  |> process.select_map(user_subject, fn(msg) { User(msg) })
  |> process.select_map(internal_subject, fn(msg) { Internal(msg) })
  // Listen for TCP close events
  |> process.select_record(atom.create("tcp_closed"), 1, fn(_) {
    Internal(SocketClose)
  })
  // Listen for SSL close events  
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_) {
    Internal(SocketClose)
  })
}

pub fn send_response(transport: Transport, socket: Socket) -> Result(Nil, Nil) {
  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_header("cache-control", "no-cache")
  |> response.set_header("connection", "keep-alive")
  |> encoder.setup_encoded_response()
  |> transport.send(transport, socket, _)
  |> result.replace_error(Nil)
}

pub fn start(
  transport: Transport,
  socket: Socket,
  on_init: fn(Subject(user_message)) -> user_state,
  handler: fn(SSEConnection, user_state, user_message) -> SSENext(user_state),
) -> Result(#(Selector(process.Down), Subject(Internal)), actor.StartError) {
  let internal_subject = process.new_subject()

  actor.new_with_initialiser(1000, fn(_subject) {
    let subject = process.new_subject()
    let state = on_init(subject)

    actor.initialised(state)
    |> actor.selecting(create_socket_selector(subject, internal_subject))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    case message {
      User(message) -> {
        case handler(SSEConnection(transport, socket), state, message) {
          Continue(new_state) -> actor.continue(new_state)
          NormalStop -> {
            echo "normal stop :)" as "potential `on_close` callback?"
            actor.stop()
          }
          AbnormalStop(reason) -> {
            echo reason as "potential `on_close` callback?"
            actor.stop_abnormal(reason)
          }
        }
      }
      Internal(SocketClose) -> {
        echo "socket close" as "potential `on_close` callback?"
        actor.stop()
      }
      Internal(Down) -> {
        echo "internal stop" as "potential `on_close` callback?"
        actor.stop()
      }
    }
  })
  |> actor.start()
  |> result.map(fn(started) {
    let assert Ok(pid) = process.subject_owner(started.data)

    #(
      process.select_specific_monitor(
        process.new_selector(),
        process.monitor(pid),
        function.identity,
      ),
      internal_subject,
    )
  })
}

pub fn send_event(
  transport: Transport,
  socket: Socket,
  event: SSEEvent,
) -> Result(Nil, socket.SocketReason) {
  let id =
    option.map(event.id, format("id", _))
    |> option.unwrap("")

  let retry =
    option.map(event.retry, int.to_string)
    |> option.map(format("retry", _))
    |> option.unwrap("")

  let data =
    string_tree.from_string(event.data)
    |> string_tree.split("\n")
    |> list.map(string_tree.prepend(_, "data: "))
    |> string_tree.join("\n")

  let event =
    option.map(event.event, format("event", _))
    |> option.unwrap("")

  string_tree.new()
  |> string_tree.append(event)
  |> string_tree.append(id)
  |> string_tree.append(retry)
  |> string_tree.append_tree(data)
  |> string_tree.append("\n\n")
  |> bytes_tree.from_string_tree()
  |> transport.send(transport, socket, _)
}

fn format(field: String, value: String) {
  field <> ": " <> value <> "\n"
}
