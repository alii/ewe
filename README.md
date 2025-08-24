# (⚠️ WIP) 🐑 ewe

ewe [/juː/] - fluffy package for building web servers. Heavily inspired by [mist](https://github.com/rawhat/mist).

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.2.0 gleam_http gleam_erlang
```

## Usage

⚠️ This package is in WIP stage, so public API will change quite often.

```gleam
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/result

import ewe

pub fn main() {
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all()
    |> ewe.with_port(4000)
    |> ewe.start()

  process.sleep_forever()
}

pub fn handler(req: Request(ewe.Connection)) -> Response(bytes_tree.BytesTree) {
  case request.path_segments(req) {
    ["hello", name] ->
      response.new(200)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(bytes_tree.from_string("Hello, " <> name <> "!"))
    ["echo"] -> handle_echo(req)
    _ ->
      response.new(404)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(bytes_tree.from_string("Not found"))
  }
}

pub fn handle_echo(
  req: Request(ewe.Connection),
) -> Response(bytes_tree.BytesTree) {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("text/plain")

  case ewe.read_body(req, 1024) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(bytes_tree.from_bit_array(req.body))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(bytes_tree.from_string("Request body is too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(bytes_tree.from_string("Invalid request body"))
  }
}
```