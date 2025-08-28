# (⚠️ WIP) 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.3.0 gleam_http gleam_erlang gleam_json
```

## Usage

⚠️ This package is in WIP stage, so public API will change quite often.

```gleam
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/result
import gleam/string_tree.{type StringTree}

import ewe

fn error_json(error: String) -> StringTree {
  json.object([#("error", json.string(error))])
  |> json.to_string_tree()
}

fn read_body_error_handler(e: ewe.BodyError) -> Response(BytesTree) {
  let error_message = case e {
    ewe.BodyTooLarge -> "Request body is too large"
    ewe.InvalidBody -> "Invalid request body"
  }

  response.new(400)
  |> ewe.json(error_json(error_message))
}

pub fn main() {
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.with_read_body(1024, read_body_error_handler)
    |> ewe.on_crash(
      error_json("Something went wrong, try again later")
      |> ewe.json(response.new(500), _),
    )
    |> ewe.bind_all()
    |> ewe.with_port(4000)
    |> ewe.start()

  process.sleep_forever()
}

pub fn handler(req: Request(BitArray)) -> Response(bytes_tree.BytesTree) {
  case request.path_segments(req) {
    ["hello", name] ->
      response.new(200)
      |> ewe.text("Hello, " <> name <> "!")
    ["echo"] -> handle_echo(req)
    _ ->
      response.new(404)
      |> ewe.json(error_json("Not found"))
  }
}

pub fn handle_echo(req: Request(BitArray)) -> Response(bytes_tree.BytesTree) {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  response.new(200)
  |> ewe.bytes(bytes_tree.from_bit_array(req.body))
  |> response.set_header("content-type", content_type)
}
```