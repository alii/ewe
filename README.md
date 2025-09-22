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
import ewe.{type Request, type Response}
import gleam/erlang/process
import gleam/http/response

pub fn main() {
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all()
    |> ewe.listening(port: 4000)
    |> ewe.start()

  process.sleep_forever()
}

fn handler(_req: Request) -> Response {
  "Hello, World!"
  |> ewe.TextData
  |> response.set_body(response.new(200), _)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
}
```

## Usage

### Sending Response

`ewe` provides several response body types (see [`ResponseBody`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#ResponseBody) type). Request handler must return `Response` type with `ResponseBody`. You can also use `ewe.Request`/`ewe.Response` as they are aliases for `Request(Connection)`/`Response(ResponseBody)`.


```gleam
import ewe.{type Connection, type ResponseBody}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

fn handler(req: Request(Connection)) -> Response(ResponseBody) {
  case request.path_segments(req) {
    ["ping"] -> {
      response.new(200)
      |> response.set_body(ewe.TextData("pong"))
      |> response.set_header("content-type", "text/plain; charset=utf-8")
    }
    ["hello", name] -> {
      { "Hello, " <> name <> "!" }
      |> ewe.TextData
      |> response.set_body(response.new(200), _)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
    }
    _ -> response.new(404) |> response.set_body(ewe.Empty)
  }
}
```

### Getting Request Body

To read the body of a request, use [`ewe.read_body`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#read_body). This function is intended for cases where the entire body can safely be loaded into memory.

```gleam
import ewe.{type Request, type Response}
import gleam/http/request
import gleam/http/response
import gleam/result

fn handle_echo(req: Request) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  case ewe.read_body(req, 1024) {
    Ok(req) ->
      ewe.BitsData(req.body)
      |> response.set_body(response.new(200), _)
      |> response.set_header("content-type", content_type)
    Error(_) -> {
      "Invalid request"
      |> ewe.TextData
      |> response.set_body(response.new(400), _)
    }
  }
}
```

### Streaming

For larger request bodies, [`ewe.stream_body`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#stream_body) provides a streaming interface. It produces a `Consumer` which can be called repeatedly to read fixed-size chunks. This enables efficient handling of large payloads without buffering them fully.


```gleam
import ewe.{type Request, type Response}
import gleam/bit_array
import gleam/http/response
import gleam/int
import gleam/yielder
import logging

fn consume_body(
  size: Int,
) -> fn(ewe.Consumer) -> yielder.Step(BitArray, ewe.Consumer) {
  fn(consumer) {
    case consumer(size) {
      Ok(ewe.Consumed(data, next)) -> {
        { "Consumed " <> int.to_string(bit_array.byte_size(data)) <> " bytes" }
        |> logging.log(logging.Info, _)

        yielder.Next(data, next)
      }
      Ok(ewe.Done) | Error(_) -> yielder.Done
    }
  }
}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let assert Ok(consumer) = ewe.stream_body(req)

  yielder.unfold(consumer, consume_body(chunk_size))
  |> ewe.ChunkedData
  |> response.set_body(response.new(200), _)
}

pub fn main() {
  let assert Ok(_) =
    ewe.new(handle_stream(_, 5))
    |> ewe.bind_all()
    |> ewe.listening(port: 4000)
    |> ewe.start()

  process.sleep_forever()
}
```

### File Serving

Static files can be sent using [`ewe.file`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#file). It accepts a path and optional `offset`/`limit` parameters. This allows serving HTML pages, assets, or binary files with minimal effort.

```gleam
import ewe.{type Request, type Response}
import gleam/http/response
import gleam/option.{None}

fn serve_file(path: String) -> Response {
  case ewe.file(path, offset: None, limit: None) {
    Ok(file) -> {
      response.new(200)
      |> response.set_body(file)
      |> response.set_header("content-type", "text/html")
    }
    Error(_) -> {
      "File not found"
      |> ewe.TextData
      |> response.set_body(response.new(404), _)
    }
  }
}
```

## WebSocket

Use [`ewe.upgrade_websocket`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#upgrade_websocket) to switch an HTTP request into a WebSocket connection. Incoming messages are represented as [`WebsocketMessage`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#WebsocketMessage). Outgoing frames are sent with [`ewe.send_text_frame`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#send_text_frame) or [`ewe.send_binary_frame`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#send_binary_frame). Handlers control the connection lifecycle with [`WebsocketNext`](https://hexdocs.pm/ewe/1.0.0-rc2/ewe.html#WebsocketNext).

```gleam
import ewe.{type Request, type Response}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import logging

type Broadcast {
  Announcement(String)
}

type ProcessRegistryMessage {
  Register(Subject(Broadcast))
  Broadcast(Broadcast)
}

fn handle_request(
  req: Request,
  registry: Subject(ProcessRegistryMessage),
) -> Response {
  case request.path_segments(req) {
    ["ws"] ->
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) {
          let subject = process.new_subject()

          process.send(registry, Register(subject))

          logging.log(logging.Info, "WebSocket connection opened!")

          #(Nil, process.select(selector, subject))
        },
        handler: handle_websocket,
        on_close: fn(_conn, _state) {
          logging.log(logging.Info, "WebSocket connection closed!")
        },
      )
    ["ws", "announce"] -> {
      case ewe.read_body(req, 1024) {
        Ok(req) -> {
          let assert Ok(text) = bit_array.to_string(req.body)

          process.send(registry, Broadcast(Announcement(text)))
          response.new(200) |> response.set_body(ewe.Empty)
        }
        Error(_) -> response.new(400) |> response.set_body(ewe.Empty)
      }
    }
    _ -> response.new(404) |> response.set_body(ewe.Empty)
  }
}

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
    ewe.User(Announcement(text)) -> {
      let _ = ewe.send_text_frame(conn, "Announcement: " <> text)
      ewe.websocket_continue(state)
    }
    ewe.Binary(binary) -> {
      let _ = ewe.send_binary_frame(conn, binary)
      ewe.websocket_continue(state)
    }
    ewe.Text(text) -> {
      let _ = ewe.send_text_frame(conn, text)
      ewe.websocket_continue(state)
    }
  }
}
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

### Complete Example

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