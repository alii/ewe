# (⚠️ Extremely WIP) 🐑 ewe

ewe [/juː/] - fluffy package for building web servers.

[![Package Version](https://img.shields.io/hexpm/v/ewe)](https://hex.pm/packages/ewe)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/ewe/)

## Installation

```sh
gleam add ewe@0.1.0 gleam_http gleam_erlang
```

## Usage

⚠️ This package is in extremely WIP stage, so public API will change quite often.

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
    |> ewe.port(4000)
    |> ewe.bind_all()
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

  case ewe.read_body(req) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(bytes_tree.from_bit_array(req.body))
    Error(Nil) ->
      response.new(400)
      |> response.set_body(bytes_tree.from_string("Invalid request"))
  }
}
```
