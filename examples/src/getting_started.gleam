import ewe.{type Request, type Response}
import gleam/erlang/process
import gleam/http/response
import logging

pub fn main() {
  // This sets the logger to print Info level logs. I recommend using `logging`
  // package, unless you prefer other tools.
  // 
  logging.configure()
  logging.set_level(logging.Info)

  // Start the ewe web server.
  // 
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all
    |> ewe.listening(port: 8080)
    |> ewe.start

  // Put process into sleep.
  // 
  process.sleep_forever()
}

// This is the HTTP request handler.
// 
fn handler(_req: Request) -> Response {
  // When sending response with body, it is important to include `content-type`
  // header representing what type your body is. You don't need to specify
  // `content-length`, it is calculated automatically by ewe.
  // 
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(ewe.TextData("Hello, World!"))
}
