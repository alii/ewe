![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@1 gleam_erlang gleam_otp gleam_http gleam_yielder logging
```

## Quick Start

```gleam
import gleam/erlang/process
import logging
import gleam/http/response

import ewe.{type Request, type Response}

fn handler(_req: Request) -> Response {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
```

## Usage

### [Sending Response](test/preview/sending_response.gleam)

`ewe` provides several response body types (see [`ewe.ResponseBody`](https://hexdocs.pm/ewe/ewe.html#ResponseBody) type). Request handler must return [`response.Response`](https://hexdocs.pm/gleam_http/gleam/http/response.html#Response) type with [`ewe.ResponseBody`](https://hexdocs.pm/ewe/ewe.html#ResponseBody). You can also use [`ewe.Request`](https://hexdocs.pm/ewe/ewe.html#Request)/[`ewe.Response`](https://hexdocs.pm/ewe/ewe.html#Response) as they are aliases for `request.Request(Connection)`(see [`request.Request`](https://hexdocs.pm/gleam_http/gleam/http/request.html#Request) & [`ewe.Connection`](https://hexdocs.pm/ewe/ewe.html#Connection))/`response.Response(ResponseBody)`.


```gleam
import gleam/crypto
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/result

import ewe.{type Connection, type ResponseBody}

fn handler(req: Request(Connection)) -> Response(ResponseBody) {
  case request.path_segments(req) {
    ["hello", name] -> {
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Hello, " <> name <> "!"))
    }
    ["bytes", amount] -> {
      let random_bytes =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes()

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(ewe.BitsData(random_bytes))
    }
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
```

### [Getting Request Body](test/preview/getting_request_body.gleam)

To read the body of a request, use [`ewe.read_body`](https://hexdocs.pm/ewe/ewe.html#read_body). This function is intended for cases where the entire body can safely be loaded into memory.

```gleam
import gleam/http/request
import gleam/http/response
import gleam/result

import ewe.{type Request, type Response}

fn handle_echo(req: Request) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.read_body(req, 1024) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.BitsData(req.body))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Body too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}
```

### [Streaming](test/preview/streaming.gleam)

For larger request bodies, [`ewe.stream_body`](https://hexdocs.pm/ewe/ewe.html#stream_body) provides a streaming interface. It produces a [`ewe.Consumer`](https://hexdocs.pm/ewe/ewe.html#Consumer) which can be called repeatedly to read fixed-size chunks. This enables efficient handling of large payloads without buffering them fully.


```gleam
import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import gleam/yielder
import logging

import ewe.{type Request, type Response}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.stream_body(req) {
    Ok(consumer) -> {
      let yielder =
        yielder.unfold(consumer, fn(consumer) {
          case consumer(chunk_size) {
            Ok(ewe.Consumed(data, next)) -> {
              logging.log(logging.Info, {
                "Consumed "
                <> int.to_string(bit_array.byte_size(data))
                <> " bytes: "
                <> string.inspect(data)
              })

              yielder.Next(data, next)
            }
            Ok(ewe.Done) | Error(_) -> yielder.Done
          }
        })

      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.ChunkedData(yielder))
    }
    Error(_) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}
```

### [File Serving](test/preview/file_serving.gleam)

Static files can be sent using [`ewe.file`](https://hexdocs.pm/ewe/ewe.html#file). It accepts a path and optional `offset`/`limit` parameters. This allows serving HTML pages, assets, or binary files with minimal effort.

```gleam
import gleam/http/response
import gleam/option.{None}

import ewe.{type Response}

fn serve_file(path: String) -> Response {
  case ewe.file("public" <> path, offset: None, limit: None) {
    Ok(file) -> {
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(file)
    }
    Error(_) -> {
      response.new(404)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("File not found"))
    }
  }
}
```

## [WebSocket](test/preview/websocket.gleam)

Use [`ewe.upgrade_websocket`](https://hexdocs.pm/ewe/ewe.html#upgrade_websocket) to switch an HTTP request into a WebSocket connection. Incoming messages are represented as [`ewe.WebsocketMessage`](https://hexdocs.pm/ewe/ewe.html#WebsocketMessage). Outgoing frames are sent with [`ewe.send_text_frame`](https://hexdocs.pm/ewe/ewe.html#send_text_frame) or [`ewe.send_binary_frame`](https://hexdocs.pm/ewe/ewe.html#send_binary_frame). Handlers control the connection lifecycle with [`ewe.WebsocketNext`](https://hexdocs.pm/ewe/ewe.html#WebsocketNext).

```gleam
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Pid, type Subject}
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

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
```

### [Server-Sent Events](test/preview/sse.gleam)


Use [`ewe.sse`](https://hexdocs.pm/ewe/ewe.html#sse) to establish a Server-Sent Events connection for real-time data streaming to clients. The connection is managed through [`ewe.SSEConnection`](https://hexdocs.pm/ewe/ewe.html#SSEConnection) and events are sent with [`ewe.send_event`](https://hexdocs.pm/ewe/ewe.html#send_event). Handlers control the connection lifecycle with [`ewe.SSENext`](https://hexdocs.pm/ewe/ewe.html#SSENext). This enables efficient one-way communication for live updates, notifications, or real-time data feeds.

```gleam
import gleam/bit_array
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import logging

import ewe.{type Request, type Response}

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
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

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
```

### [Complete Preview](test/preview.gleam)

```gleam
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import gleam/yielder
import logging

import ewe.{type Request, type Response}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Create a named subject for the pubsub worker
  let pubsub_name = process.new_name("pubsub")
  let pubsub = process.named_subject(pubsub_name)

  // Configure and start the supervision tree with pubsub worker and the ewe 
  // server, that listens on port 8080
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

// Define the messages that can be sent to the pubsub worker
type PubSubMessage {
  Subscribe(topic: String, client: Subject(Broadcast))
  Publish(topic: String, message: Broadcast)
  Unsubscribe(topic: String, client: Subject(Broadcast))
}

// Define the messages that could be received by websocket and SSE clients
type Broadcast {
  Text(String)
  Bytes(BitArray)
}

// Define the state of the websocket connection
type WebsocketState {
  WebsocketState(
    pubsub: Subject(PubSubMessage),
    topic: String,
    client: Subject(Broadcast),
  )
}

// Main logic of the pubsub worker, that handles the messages and keeps track of
// the clients on topics. Its implementation is not really important
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

// Main HTTP request handler that routes requests to different endpoints
fn handler(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    // GET /hello/:name - Simple greeting endpoint
    ["hello", name] -> {
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Hello, " <> name <> "!"))
    }
    // GET /bytes/:amount - Generate random N bytes
    ["bytes", amount] -> {
      let random_bytes =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes()

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(ewe.BitsData(random_bytes))
    }

    // POST /echo - Echo back the request body
    ["echo"] -> handle_echo(req)
    // POST /stream/:chunk_size - Stream and echo back the request body in chunks
    ["stream", chunk_size] ->
      handle_stream(req, int.parse(chunk_size) |> result.unwrap(16))

    // GET /file/:path - Serve a file from the public directory
    ["file", path] -> serve_file(path)

    // POST /topic/:topic/ws - Upgrade to WebSocket connection
    ["topic", topic, "ws"] ->
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

    // POST /topic/:topic/sse - Switch to Server-Sent Events connection
    ["topic", topic, "sse"] ->
      ewe.sse(
        req,
        on_init: fn(client) {
          logging.log(
            logging.Info,
            "SSE connection opened: " <> pid_to_string(process.self()),
          )

          process.send(pubsub, Subscribe(topic:, client:))
          client
        },
        handler: fn(conn, client, message) {
          let assert Ok(_) = case message {
            Text(text) -> ewe.send_event(conn, ewe.event(text))
            _ -> Ok(Nil)
          }

          ewe.sse_continue(client)
        },
        on_close: fn(_conn, client) {
          logging.log(
            logging.Info,
            "SSE connection closed: " <> pid_to_string(process.self()),
          )

          process.send(pubsub, Unsubscribe(topic:, client:))
        },
      )

    // All other routes return 404
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

fn handle_echo(req: Request) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.read_body(req, 1024) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.BitsData(req.body))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Body too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.stream_body(req) {
    Ok(consumer) -> {
      let yielder =
        yielder.unfold(consumer, fn(consumer) {
          case consumer(chunk_size) {
            Ok(ewe.Consumed(data, next)) -> {
              logging.log(logging.Info, {
                "Consumed "
                <> int.to_string(bit_array.byte_size(data))
                <> " bytes: "
                <> string.inspect(data)
              })

              yielder.Next(data, next)
            }
            Ok(ewe.Done) | Error(_) -> yielder.Done
          }
        })

      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.ChunkedData(yielder))
    }
    Error(_) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

fn serve_file(path: String) -> Response {
  case ewe.file("public" <> path, offset: None, limit: None) {
    Ok(file) -> {
      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(file)
    }
    Error(_) -> {
      response.new(404)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("File not found"))
    }
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

fn pid_to_string(pid: Pid) -> String {
  charlist.to_string(pid_to_list(pid))
}

@external(erlang, "erlang", "pid_to_list")
fn pid_to_list(pid: Pid) -> Charlist
```

## API Reference

For detailed API documentation, see [hexdocs.pm/ewe](https://hexdocs.pm/ewe/ewe.html).