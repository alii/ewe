import gleam/erlang/process
import logging

import gleam/crypto
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/result

import ewe.{type Connection, type ResponseBody}

fn handler(req: Request(Connection)) -> Response(ResponseBody) {
  case request.path_segments(req) {
    ["hello", name] -> {
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Hello, " <> name <> "!"))
    }
    ["bytes", amount] -> {
      let random_bytes =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes()

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(ewe.BitsData(random_bytes))
    }
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
