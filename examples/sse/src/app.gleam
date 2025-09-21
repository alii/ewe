import gleam/bit_array
import gleam/erlang/charlist
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import logging

import ewe

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
}

// If 8080 is already in use, you can change the port here
const port = 8080

fn handle_pubsub_message(clients: List(Subject(String)), message: PubSubMessage) {
  case message {
    Subscribe(client) -> {
      let assert Ok(pid) = process.subject_owner(client)

      logging.log(logging.Info, "Client " <> pid_to_string(pid) <> " connected")

      actor.continue([client, ..clients])
    }

    Unsubscribe(client) -> {
      let assert Ok(pid) = process.subject_owner(client)

      let message = "Client " <> pid_to_string(pid) <> " disconnected"
      logging.log(logging.Info, message)

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

      let message = "Sent message `" <> message <> "` to clients: " <> pids
      logging.log(logging.Info, message)

      actor.continue(clients)
    }
  }
}

pub fn main() -> Nil {
  logging.configure()

  let pubsub = process.new_name("pubsub")

  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(pubsub_worker(pubsub))
    |> supervisor.add(web_server(pubsub))
    |> supervisor.start()

  process.sleep_forever()
}

fn pubsub_worker(
  named: Name(PubSubMessage),
) -> ChildSpecification(Subject(PubSubMessage)) {
  supervision.worker(fn() {
    actor.new([])
    |> actor.on_message(handle_pubsub_message)
    |> actor.named(named)
    |> actor.start()
  })
}

fn web_server(pubsub: Name(PubSubMessage)) -> ChildSpecification(Supervisor) {
  ewe.new(handle_request(_, process.named_subject(pubsub)))
  |> ewe.listening(port: port)
  |> ewe.bind_all()
  |> ewe.supervised()
}

fn empty_response(status: Int) -> ewe.Response {
  response.new(status) |> response.set_body(ewe.Empty)
}

fn handle_request(
  req: ewe.Request,
  pubsub: Subject(PubSubMessage),
) -> ewe.Response {
  case req.method, req.path {
    // On `GET /`, serve the index.html file
    http.Get, "/" -> {
      case ewe.file("priv/index.html", offset: None, limit: None) {
        Ok(file) -> {
          response.new(200)
          |> response.set_body(file)
          |> response.set_header("content-type", "text/html")
        }
        Error(_) -> empty_response(500)
      }
    }

    // On `GET /sse`, start a Server-Sent Events connection
    http.Get, "/sse" ->
      ewe.sse(
        req,
        on_init: fn(client) {
          process.send(pubsub, Subscribe(client))

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
        },
      )

    // On `POST /post`, publish the body to the pubsub
    http.Post, "/post" -> {
      // `128` is the limit of the body size in the frontend (see L66 of
      // `index.html`)
      case ewe.read_body(req, 128) {
        Ok(req) -> {
          case bit_array.to_string(req.body) {
            Ok(message) -> {
              process.send(pubsub, Publish(message))

              empty_response(200)
            }
            Error(Nil) -> empty_response(400)
          }
        }
        Error(_) -> empty_response(400)
      }
    }

    _, _ -> empty_response(404)
  }
}

fn pid_to_string(pid: Pid) -> String {
  pid_to_list(pid)
  |> charlist.to_string()
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> charlist.Charlist
