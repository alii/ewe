import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}

import gleam/bit_array
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import logging

import ewe.{type Request, type Response}

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
}

fn pubsub_worker(
  named: Name(PubSubMessage),
) -> ChildSpecification(Subject(PubSubMessage)) {
  let pubsub =
    actor.new([])
    |> actor.on_message(fn(clients, message) {
      case message {
        Subscribe(client) -> {
          let assert Ok(pid) = process.subject_owner(client)

          logging.log(
            logging.Info,
            "Client " <> pid_to_string(pid) <> " subscribed",
          )

          actor.continue([client, ..clients])
        }

        Unsubscribe(client) -> {
          let assert Ok(pid) = process.subject_owner(client)

          { "Client " <> pid_to_string(pid) <> " unsubscribed" }
          |> logging.log(logging.Info, _)

          list.filter(clients, fn(subscribed) { subscribed != client })
          |> actor.continue()
        }

        Publish(message) -> {
          let pids =
            list.fold(over: clients, from: [], with: fn(acc, client) {
              let assert Ok(pid) = process.subject_owner(client)
              let _ = process.send(client, message)

              [pid_to_string(pid), ..acc]
            })
            |> string.join(", ")

          { "Publishing message `" <> message <> "` to clients: " <> pids }
          |> logging.log(logging.Info, _)

          actor.continue(clients)
        }
      }
    })
    |> actor.named(named)

  supervision.worker(fn() { actor.start(pubsub) })
}

fn handler(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    ["sse"] ->
      ewe.sse(
        req,
        on_init: fn(client) {
          process.send(pubsub, Subscribe(client))
          logging.log(
            logging.Info,
            "SSE connection opened: " <> pid_to_string(process.self()),
          )

          client
        },
        handler: fn(conn, client, message) {
          case ewe.send_event(conn, ewe.event(message)) {
            Ok(Nil) -> ewe.sse_continue(client)
            Error(_) -> ewe.sse_stop()
          }
        },
        on_close: fn(_conn, client) {
          process.send(pubsub, Unsubscribe(client))
          logging.log(
            logging.Info,
            "SSE connection closed: " <> pid_to_string(process.self()),
          )
        },
      )
    ["publish"] -> {
      case ewe.read_body(req, 1024) {
        Ok(req) -> {
          let assert Ok(text) = bit_array.to_string(req.body)
          process.send(pubsub, Publish(text))
          response.new(200) |> response.set_body(ewe.Empty)
        }
        Error(_) -> response.new(400) |> response.set_body(ewe.Empty)
      }
    }
    _ -> response.new(404) |> response.set_body(ewe.Empty)
  }
}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let pubsub_name = process.new_name("pubsub")
  let pubsub = process.named_subject(pubsub_name)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub_worker(pubsub_name))
    |> supervisor.add(
      ewe.new(handler(_, pubsub))
      |> ewe.bind_all()
      |> ewe.listening(port: 8080)
      |> ewe.supervised(),
    )
    |> supervisor.start()

  process.sleep_forever()
}

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
