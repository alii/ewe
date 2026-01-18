import ewe.{type Connection, type ResponseBody}
import gleam/crypto
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/result
import logging

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // A server demonstrating different response body types and path routing.
  // 
  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all
    |> ewe.listening(port: 8080)
    |> ewe.start

  process.sleep_forever()
}

fn handler(req: Request(Connection)) -> Response(ResponseBody) {
  // Pattern match on path segments for cleaner routing.
  // Example: "/hello/alice" becomes ["hello", "alice"]
  // 
  case request.path_segments(req) {
    ["hello", name] -> {
      // Here, we will use TextData for text responses.
      // 
      response.new(200)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Hello, " <> name <> "!"))
    }
    ["bytes", amount] -> {
      // Use BitsData for binary responses. We generate random bytes
      // to demonstrate sending binary data.
      // 
      let body =
        int.parse(amount)
        |> result.unwrap(0)
        |> crypto.strong_random_bytes
        |> ewe.BitsData

      response.new(200)
      |> response.set_header("content-type", "application/octet-stream")
      |> response.set_body(body)
    }
    _ ->
      // Use Empty for responses with no body (like 404, 204, etc).
      // You don't need to set content-type for empty bodies.
      // 
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}
