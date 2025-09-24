import gleam/erlang/process
import gleam/http/response

import ewe.{type Request, type Response}

fn handler(_req: Request) -> Response {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}

pub fn main() {
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
