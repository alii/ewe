![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.10.0 gleam_erlang gleam_otp gleam_http gleam_yielder
```

## Usage

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
) -> ewe.Next(Nil, Broadcast) {
  case msg {
    ewe.Text("Ping") -> {
      let _ = ewe.send_text_frame(conn, "Pong")
      ewe.continue(state)
    }
    ewe.Text("Exit") -> ewe.stop()

    // Handle broadcast messages from registry
    ewe.User(Announcement(text)) -> {
      let _ = ewe.send_text_frame(conn, "Announcement: " <> text)
      ewe.continue(state)
    }

    // Echo binary frames back to client
    ewe.Binary(binary) -> {
      let _ = ewe.send_binary_frame(conn, binary)
      ewe.continue(state)
    }
    // Echo text frames back to client
    ewe.Text(text) -> {
      let _ = ewe.send_text_frame(conn, text)
      ewe.continue(state)
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