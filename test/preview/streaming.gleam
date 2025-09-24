import gleam/erlang/process
import gleam/string

import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import gleam/yielder
import logging

import ewe.{type Request, type Response}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.stream_body(req) {
    Ok(consumer) -> {
      let yielder =
        yielder.unfold(consumer, fn(consumer) {
          case consumer(chunk_size) {
            Ok(ewe.Consumed(data, next)) -> {
              logging.log(logging.Info, {
                "Consumed "
                <> int.to_string(bit_array.byte_size(data))
                <> " bytes: "
                <> string.inspect(data)
              })

              yielder.Next(data, next)
            }
            Ok(ewe.Done) | Error(_) -> yielder.Done
          }
        })

      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.ChunkedData(yielder))
    }
    Error(_) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

fn handler(req: Request) -> Response {
  case request.path_segments(req) {
    ["stream", chunk_size] ->
      int.parse(chunk_size)
      |> result.unwrap(16)
      |> handle_stream(req, _)
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
