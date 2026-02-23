import ewe.{type Request, type Response}
import gleam/erlang/process
import gleam/http/response
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Debug)

  // Start the server that has TLS enabled.
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind("0.0.0.0")
    |> ewe.listening(port: 8080)
    |> ewe.enable_tls(
      certificate_file: "examples/priv/localhost.crt",
      key_file: "examples/priv/localhost.key",
    )
    |> ewe.start

  process.sleep_forever()
}

fn handler(_req: Request) -> Response {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}
