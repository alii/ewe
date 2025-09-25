import gleam/erlang/process
import logging

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

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    ewe.new(fn(req) { serve_file(req.path) })
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
