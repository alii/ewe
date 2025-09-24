![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@1.0.0-rc2 gleam_erlang gleam_otp gleam_http gleam_yielder logging
```

## Quick Start

```gleam
import gleam/erlang/process
import gleam/http/response

import ewe.{type Request, type Response}

fn handler(_req: Request) -> Response {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}

pub fn main() {
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

`ewe` provides several response body types (see [`ResponseBody`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#ResponseBody) type). Request handler must return `Response` type with `ResponseBody`. You can also use `ewe.Request`/`ewe.Response` as they are aliases for `Request(Connection)`/`Response(ResponseBody)`.


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

To read the body of a request, use [`ewe.read_body`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#read_body). This function is intended for cases where the entire body can safely be loaded into memory.

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

For larger request bodies, [`ewe.stream_body`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#stream_body) provides a streaming interface. It produces a `Consumer` which can be called repeatedly to read fixed-size chunks. This enables efficient handling of large payloads without buffering them fully.


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

Static files can be sent using [`ewe.file`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#file). It accepts a path and optional `offset`/`limit` parameters. This allows serving HTML pages, assets, or binary files with minimal effort.

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

Use [`ewe.upgrade_websocket`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#upgrade_websocket) to switch an HTTP request into a WebSocket connection. Incoming messages are represented as [`WebsocketMessage`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#WebsocketMessage). Outgoing frames are sent with [`ewe.send_text_frame`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#send_text_frame) or [`ewe.send_binary_frame`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#send_binary_frame). Handlers control the connection lifecycle with [`WebsocketNext`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#WebsocketNext).

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

### Server-Sent Events


Use [`ewe.sse`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#sse) to establish a Server-Sent Events connection for real-time data streaming to clients. The connection is managed through [`SSEConnection`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#SSEConnection) and events are sent with [`ewe.send_event`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#send_event). Handlers control the connection lifecycle with [`SSENext`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#SSENext). This enables efficient one-way communication for live updates, notifications, or real-time data feeds.

```gleam
import ewe.{type Request, type Response}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import logging

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
}

fn handle_request(req: Request, pubsub: Subject(PubSubMessage)) -> Response {
  case request.path_segments(req) {
    ["sse"] ->
      ewe.sse(
        req,
        on_init: fn(client) {
          process.send(pubsub, Subscribe(client))
          logging.log(logging.Info, "SSE connection opened!")
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
          logging.log(logging.Info, "SSE connection closed!")
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
```

### Complete Preview

```gleam
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/yielder

import ewe.{type Request, type Response}

pub fn main() {
  // Start a process registry to manage WebSocket connections
  let assert Ok(started) = process_registry()
  let registry = started.data

  // Define crash response for server errors
  let on_crash =
    "Something went wrong, try again later"
    |> ewe.TextData
    |> response.set_body(response.new(500), _)

  // Configure and start the web server on port 4000
  let assert Ok(_) =
    ewe.new(handler(_, registry))
    |> ewe.on_crash(on_crash)
    |> ewe.bind_all()
    |> ewe.listening(port: 4000)
    |> ewe.start()

  process.sleep_forever()
}

// Main HTTP request handler that routes requests to different endpoints
fn handler(req: Request, registry: Subject(ProcessRegistryMessage)) -> Response {
  case request.path_segments(req) {
    // GET /hello/:name - Simple greeting endpoint
    ["hello", name] -> {
      { "Hello, " <> name <> "!" }
      |> ewe.TextData
      |> response.set_body(response.new(200), _)
    }
    // POST /echo - Echo request body back to client
    ["echo"] -> handle_echo(req, None)
    // POST /stream/:size - Stream request body in chunks
    ["stream", sized] -> handle_echo(req, Some(sized))
    // WebSocket upgrade endpoint
    ["ws"] ->
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) {
          let subject = process.new_subject()
          register(registry, subject)

          io.println("WebSocket connection established!")

          #(Nil, process.select(selector, subject))
        },
        handler: handle_websocket,
        on_close: fn(_conn, _state) {
          io.println("WebSocket connection closed!")
        },
      )
    // POST /ws/announce/:text - Broadcast message to all WebSocket connections
    ["ws", "announce", text] -> {
      announce(registry, text)

      response.new(200)
      |> response.set_body(ewe.Empty)
    }
    // 404 for unknown routes
    _ -> {
      "Unknown endpoint"
      |> ewe.TextData
      |> response.set_body(response.new(404), _)
    }
  }
}

// Helper function to consume request body in chunks for streaming
fn consume_body(
  size: Int,
) -> fn(ewe.Consumer) -> yielder.Step(BitArray, ewe.Consumer) {
  fn(consumer) {
    case consumer(size) {
      Ok(ewe.Consumed(data, next)) -> {
        io.println(
          "Consumed "
          <> int.to_string(bit_array.byte_size(data))
          <> " bytes: "
          <> bit_array.to_string(data) |> result.unwrap(""),
        )
        yielder.Next(data, next)
      }
      Ok(ewe.Done) | Error(_) -> yielder.Done
    }
  }
}

// Handler for echo endpoints - returns request body back to client
fn handle_echo(req: Request, stream: Option(String)) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  let invalid_body =
    "Invalid request"
    |> ewe.TextData
    |> response.set_body(response.new(400), _)

  case option.map(stream, int.parse) {
    // Stream mode: return body as chunked response
    Some(Ok(size)) -> {
      let assert Ok(consumer) = ewe.stream_body(req)

      yielder.unfold(consumer, consume_body(size))
      |> ewe.ChunkedData
      |> response.set_body(response.new(200), _)
      |> response.set_header("content-type", content_type)
    }
    Some(Error(_)) -> invalid_body
    // Regular mode: read entire body and echo back
    None -> {
      case ewe.read_body(req, 1024) {
        Ok(req) ->
          ewe.BitsData(req.body)
          |> response.set_body(response.new(200), _)
          |> response.set_header("content-type", content_type)
        Error(_) -> invalid_body
      }
    }
  }
}

type Broadcast {
  Announcement(String)
}

// WebSocket message handler - processes incoming WebSocket frames
fn handle_websocket(
  conn: ewe.WebsocketConnection,
  state: Nil,
  msg: ewe.WebsocketMessage(Broadcast),
) -> ewe.WebsocketNext(Nil, Broadcast) {
  case msg {
    ewe.Text("Ping") -> {
      let _ = ewe.send_text_frame(conn, "Pong")
      ewe.websocket_continue(state)
    }
    ewe.Text("Exit") -> ewe.websocket_stop()

    // Handle broadcast messages from registry
    ewe.User(Announcement(text)) -> {
      let _ = ewe.send_text_frame(conn, "Announcement: " <> text)
      ewe.websocket_continue(state)
    }

    // Echo binary frames back to client
    ewe.Binary(binary) -> {
      let _ = ewe.send_binary_frame(conn, binary)
      ewe.websocket_continue(state)
    }
    // Echo text frames back to client
    ewe.Text(text) -> {
      let _ = ewe.send_text_frame(conn, text)
      ewe.websocket_continue(state)
    }
  }
}

type ProcessRegistryMessage {
  Register(Subject(Broadcast))
  Announce(Broadcast)
}

// Creates a registry actor to manage WebSocket connections for broadcasting
fn process_registry() -> Result(
  actor.Started(Subject(ProcessRegistryMessage)),
  actor.StartError,
) {
  actor.new([])
  |> actor.on_message(fn(state, msg) {
    case msg {
      Register(subject) -> actor.continue([subject, ..state])
      Announce(msg) -> {
        list.each(state, fn(subject) { process.send(subject, msg) })
        actor.continue(state)
      }
    }
  })
  |> actor.start()
}

// Register a WebSocket connection with the broadcast registry
fn register(
  registry: Subject(ProcessRegistryMessage),
  subject: Subject(Broadcast),
) -> Nil {
  process.send(registry, Register(subject))
}

// Send announcement to all registered WebSocket connections
fn announce(registry: Subject(ProcessRegistryMessage), message: String) -> Nil {
  process.send(registry, Announce(Announcement(message)))
}
```

## API Reference

For detailed API documentation, see [hexdocs.pm/ewe](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html).