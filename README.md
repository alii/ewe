![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# (⚠️ WIP) 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.6.0 gleam_http gleam_erlang gleam_json
```

## Usage

⚠️ This package is in WIP stage, so public API will change quite often.

```gleam
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string_tree.{type StringTree}

import ewe

fn error_json(error: String) -> StringTree {
  json.object([#("error", json.string(error))])
  |> json.to_string_tree()
}

pub fn main() {
  let assert Ok(started) = process_registry()
  let registry = started.data

  let assert Ok(_) =
    ewe.new(handler(_, registry))
    |> ewe.on_crash(
      error_json("Something went wrong, try again later")
      |> ewe.json(response.new(500), _),
    )
    |> ewe.bind_all()
    |> ewe.listening(port: 4000)
    |> ewe.start()

  process.sleep_forever()
}

fn handler(
  req: Request(ewe.Connection),
  registry: Subject(ProcessRegistryMessage),
) -> Response(ewe.ResponseBody) {
  case request.path_segments(req) {
    ["hello", name] ->
      response.new(200)
      |> ewe.text("Hello, " <> name <> "!")
    ["echo"] -> handle_echo(req)
    ["ws"] ->
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) {
          let subject = process.new_subject()

          register(registry, subject)

          #(Nil, process.select(selector, subject))
        },
        handler: handle_websocket,
        on_close: fn(_conn, _state) { io.println("Sayonara!") },
      )
    ["ws", "announce", text] -> {
      announce(registry, text)
      ewe.empty(response.new(200))
    }
    _ ->
      response.new(404)
      |> ewe.json(error_json("Not found"))
  }
}

fn handle_echo(req: Request(ewe.Connection)) -> Response(ewe.ResponseBody) {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  use <- ewe.use_expression()

  use req <- result.try(
    ewe.read_body(req, 1024)
    |> result.replace_error(
      response.new(400)
      |> ewe.json(error_json("Invalid request body")),
    ),
  )

  response.new(200)
  |> ewe.bits(req.body)
  |> response.set_header("content-type", content_type)
  |> Ok
}

type Broadcast {
  Announcement(String)
}

fn handle_websocket(
  conn: ewe.WebsocketConnection,
  state: Nil,
  msg: ewe.WebsocketMessage(Broadcast),
) -> ewe.Next(Nil) {
  case msg {
    ewe.Text("Ping") -> {
      let _ = ewe.send_text_frame(conn, "Pong")
      ewe.continue(state)
    }
    ewe.User(Announcement(text)) -> {
      let _ = ewe.send_text_frame(conn, "Announcement: " <> text)
      ewe.continue(state)
    }
    ewe.Text("Exit") -> ewe.stop()

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

fn process_registry() {
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
) {
  process.send(registry, Register(subject))
}

fn announce(registry: Subject(ProcessRegistryMessage), message: String) {
  process.send(registry, Announce(Announcement(message)))
}
```