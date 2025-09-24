import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string

import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import logging

import ewe.{type Request, type Response}

type PubSubMessage {
  Subscribe(topic: String, client: Subject(Broadcast))
  Publish(topic: String, message: Broadcast)
  Unsubscribe(topic: String, client: Subject(Broadcast))
}

type Broadcast {
  Text(String)
  Bytes(BitArray)
}

fn pubsub_worker(
  named: Name(PubSubMessage),
) -> ChildSpecification(Subject(PubSubMessage)) {
  let pubsub =
    actor.new(dict.new())
    |> actor.on_message(fn(state, msg) {
      case msg {
        Subscribe(topic:, client:) -> {
          let new_state =
            dict.upsert(in: state, update: topic, with: fn(clients) {
              case clients {
                Some(clients) -> [client, ..clients]
                None -> {
                  logging.log(logging.Info, "Creating topic " <> topic)
                  [client]
                }
              }
            })

          let assert Ok(pid) = process.subject_owner(client)
          logging.log(
            logging.Info,
            "Subscribing client " <> pid_to_string(pid) <> " to topic " <> topic,
          )

          actor.continue(new_state)
        }
        Publish(topic:, message:) -> {
          case message {
            Text(text) ->
              logging.log(
                logging.Info,
                "Publishing text message `" <> text <> "` to topic " <> topic,
              )
            Bytes(binary) ->
              logging.log(
                logging.Info,
                "Publishing binary message `"
                  <> string.inspect(binary)
                  <> "` to topic "
                  <> topic,
              )
          }

          case dict.get(state, topic) {
            Ok(clients) -> list.each(clients, actor.send(_, message))
            Error(_) -> Nil
          }

          actor.continue(state)
        }
        Unsubscribe(topic:, client:) -> {
          let assert Ok(pid) = process.subject_owner(client)
          logging.log(
            logging.Info,
            "Unsubscribing client "
              <> pid_to_string(pid)
              <> " from topic "
              <> topic,
          )

          let new_state = case dict.get(state, topic) {
            Ok([_]) | Ok([]) -> {
              logging.log(logging.Info, "Dropping topic " <> topic)
              dict.drop(state, [topic])
            }
            Ok(clients) -> {
              list.filter(clients, fn(c) { c != client })
              |> dict.insert(state, topic, _)
            }
            Error(_) -> state
          }

          actor.continue(new_state)
        }
      }
    })
    |> actor.named(named)

  supervision.worker(fn() {
    logging.log(logging.Info, "Starting pubsub worker")
    actor.start(pubsub)
  })
}

type WebsocketState {
  WebsocketState(
    pubsub: Subject(PubSubMessage),
    topic: String,
    client: Subject(Broadcast),
  )
}

fn handler(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    ["topic", topic] ->
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) {
          logging.log(
            logging.Info,
            "WebSocket connection opened: " <> pid_to_string(process.self()),
          )

          let client = process.new_subject()
          process.send(pubsub, Subscribe(topic:, client:))

          let state = WebsocketState(pubsub:, topic:, client:)
          let selector = process.select(selector, client)

          #(state, selector)
        },
        handler: handle_websocket,
        on_close: fn(_conn, state) {
          let assert Ok(pid) = process.subject_owner(state.client)
          logging.log(
            logging.Info,
            "WebSocket connection closed: " <> pid_to_string(pid),
          )

          process.send(pubsub, Unsubscribe(state.topic, state.client))
        },
      )
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

fn handle_websocket(
  conn: ewe.WebsocketConnection,
  state: WebsocketState,
  msg: ewe.WebsocketMessage(Broadcast),
) -> ewe.WebsocketNext(WebsocketState, Broadcast) {
  case msg {
    ewe.Text(text) -> {
      process.send(state.pubsub, Publish(state.topic, Text(text)))
      ewe.websocket_continue(state)
    }

    ewe.Binary(binary) -> {
      process.send(state.pubsub, Publish(state.topic, Bytes(binary)))
      ewe.websocket_continue(state)
    }

    ewe.User(message) -> {
      let assert Ok(_) = case message {
        Text(text) -> ewe.send_text_frame(conn, text)
        Bytes(binary) -> ewe.send_binary_frame(conn, binary)
      }

      ewe.websocket_continue(state)
    }
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
