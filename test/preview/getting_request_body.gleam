import gleam/erlang/process

import gleam/http/request
import gleam/http/response
import gleam/result

import ewe.{type Request, type Response}

fn handle_echo(req: Request) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.read_body(req, 1024) {
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

pub fn main() {
  let assert Ok(_) =
    ewe.new(handle_echo)
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
