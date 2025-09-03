![ewe](https://raw.githubusercontent.com/vshakitskiy/ewe/mistress/public/banner.jpg)

# (⚠️ WIP) 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.8.1 gleam_http gleam_erlang gleam_json
```

## Usage

⚠️ This package is in WIP stage, so public API will change quite often.

```gleam
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

import ewe

const internal_error = "Something went wrong, try again later"

const not_found_error = "Not found"

const invalid_request_error = "Invalid request"

fn failed_response(status: Int, error: String) -> Response(ewe.ResponseBody) {
  json.object([#("error", json.string(error))])
  |> json.to_string_tree()
  |> ewe.json(response.new(status), _)
}

pub fn main() {
  let assert Ok(started) = process_registry()
  let registry = started.data

  let assert Ok(_) =
    ewe.new(handler(_, registry))
    |> ewe.on_crash(failed_response(500, internal_error))
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
    ["echo"] -> handle_echo(req, None)
    ["stream", sized] -> handle_echo(req, Some(sized))
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
    _ -> failed_response(404, not_found_error)
  }
}

fn consume_body(consume: ewe.Consumer, size: Int, acc: BitArray) -> BitArray {
  case consume(size) {
    Ok(ewe.Done) | Error(_) -> acc
    Ok(ewe.Consumed(data, next)) -> {
      io.println(
        "Consumed "
        <> int.to_string(bit_array.byte_size(data))
        <> " bytes: "
        <> bit_array.to_string(data) |> result.unwrap(""),
      )

      consume_body(next, size, <<acc:bits, data:bits>>)
    }
  }
}

fn handle_echo(
  req: Request(ewe.Connection),
  stream: Option(String),
) -> Response(ewe.ResponseBody) {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  let invalid_body = failed_response(400, invalid_request_error)

  case option.map(stream, int.parse) {
    Some(Ok(size)) -> {
      let assert Ok(consumer) = ewe.stream_body(req)

      let body = consume_body(consumer, size, <<>>)

      response.new(200)
      |> ewe.bits(body)
      |> response.set_header("content-type", content_type)
    }
    Some(Error(_)) -> invalid_body
    None -> {
      case ewe.read_body(req, 1024) {
        Ok(req) ->
          response.new(200)
          |> ewe.bits(req.body)
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