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
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/result
import gleam/string_tree.{type StringTree}

import ewe

fn error_json(error: String) -> StringTree {
  json.object([#("error", json.string(error))])
  |> json.to_string_tree()
}

pub fn main() {
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.on_crash(
      error_json("Something went wrong, try again later")
      |> ewe.json(response.new(500), _),
    )
    |> ewe.bind_all()
    |> ewe.with_port(4000)
    |> ewe.start()

  process.sleep_forever()
}

pub fn handler(req: Request(ewe.Connection)) -> Response(ewe.ResponseBody) {
  case request.path_segments(req) {
    ["hello", name] ->
      response.new(200)
      |> ewe.text("Hello, " <> name <> "!")
    ["echo"] -> handle_echo(req)
    ["ws"] ->
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn) { Nil },
        handler: handle_websocket,
      )
    _ ->
      response.new(404)
      |> ewe.json(error_json("Not found"))
  }
}

pub fn handle_echo(req: Request(ewe.Connection)) -> Response(ewe.ResponseBody) {
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

pub fn handle_websocket(
  conn: ewe.WebsocketConnection,
  state: Nil,
  msg: ewe.WebsocketMessage,
) -> ewe.Next(Nil) {
  case msg {
    ewe.Text("Ping") -> {
      let _ = ewe.send_text_frame(conn, "Pong")
      ewe.continue(state)
    }
    ewe.Text("Stop") -> ewe.stop()
    ewe.Text(text) -> {
      io.println("Received text: " <> text)
      ewe.continue(state)
    }
    ewe.Binary(binary) -> {
      io.println(
        "Received binary of size: "
        <> int.to_string(bit_array.byte_size(binary)),
      )
      ewe.continue(state)
    }
  }
}
```