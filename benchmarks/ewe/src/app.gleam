import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response

pub fn main() -> Nil {
  let assert Ok(_started) =
    ewe.new(fn(req) {
      case request.path_segments(req) {
        ["hello"] ->
          response.new(200)
          |> response.set_header("content-type", "text/plain; charset=utf-8")
          |> response.set_body(ewe.TextData("Hello, World!"))

        _ -> response.new(404) |> response.set_body(ewe.Empty)
      }
    })
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
