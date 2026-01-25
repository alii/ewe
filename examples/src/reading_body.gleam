import ewe.{type Request, type Response}
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/result
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // An echo server that reads the request body and sends it back.
  //
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(port: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handler(req: Request) -> Response {
  // Preserve the original content-type from the request to send back.
  //
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  // Read the entire request body into memory with a 10KB limit. This blocks
  // until the full body is received. For large uploads or streaming data,
  // use ewe.stream_body() instead.
  //
  case ewe.read_body(req, 10_240) {
    Ok(req) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_body(ewe.BitsData(req.body))
    Error(ewe.BodyTooLarge) ->
      response.new(413)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Body too large"))
    Error(ewe.InvalidBody) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}
