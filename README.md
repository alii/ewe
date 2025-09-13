![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.10.0 gleam_erlang gleam_otp gleam_http gleam_json gleam_yielder
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
  let assert Ok(started) = process_registry()
  let registry = started.data

  let assert Ok(_) =
    ewe.new(handler(_, registry))
    |> ewe.on_crash(ewe.text(
      response.new(500),
      "Something went wrong, try again later",
    ))
    |> ewe.bind_all()
    |> ewe.listening(port: 4000)
    |> ewe.start()

  process.sleep_forever()
}

fn handler(req: Request, registry: Subject(ProcessRegistryMessage)) -> Response {
  case request.path_segments(req) {
    ["hello", name] -> ewe.text(response.new(200), "Hello, " <> name <> "!")
    ["echo"] -> handle_echo(req, None)
    ["stream", sized] -> handle_echo(req, Some(sized))
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
    ["ws", "announce", text] -> {
      announce(registry, text)
      ewe.empty(response.new(200))
    }
    _ -> ewe.text(response.new(404), "Unknown endpoint")
  }
}

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

fn handle_echo(req: Request, stream: Option(String)) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  let invalid_body = ewe.text(response.new(400), "Invalid request")

  case option.map(stream, int.parse) {
    Some(Ok(size)) -> {
      let assert Ok(consumer) = ewe.stream_body(req)

      response.new(200)
      |> ewe.chunked(yielder.unfold(consumer, consume_body(size)))
      |> response.set_header("content-type", content_type)
    }
    Some(Error(_)) -> invalid_body
    None -> {
      case ewe.read_body(req, 1024) {
        Ok(req) ->
          ewe.bits(response.new(200), req.body)
          |> response.set_header("content-type", content_type)
        Error(_) -> invalid_body
      }
    }
  }
}

type Broadcast {
  Announcement(String)
}

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

    ewe.User(Announcement(text)) -> {
      let _ = ewe.send_text_frame(conn, "Announcement: " <> text)
      ewe.continue(state)
    }

    ewe.Binary(binary) -> {
      let _ = ewe.send_binary_frame(conn, binary)
      ewe.continue(state)
    }
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

fn register(
  registry: Subject(ProcessRegistryMessage),
  subject: Subject(Broadcast),
) -> Nil {
  process.send(registry, Register(subject))
}

fn announce(registry: Subject(ProcessRegistryMessage), message: String) -> Nil {
  process.send(registry, Announce(Announcement(message)))
}
```