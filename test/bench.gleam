import ewe
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/result

pub fn main() {
  let empty_response =
    response.new(200)
    |> response.set_body(ewe.Empty)

  let not_found =
    response.new(404)
    |> response.set_body(ewe.Empty)

  let too_large =
    response.new(413)
    |> response.set_body(ewe.Empty)

  let assert Ok(_) =
    fn(req: Request(ewe.Connection)) {
      case req.method, request.path_segments(req) {
        http.Get, [] -> empty_response
        http.Get, ["user", id] ->
          response.new(200) |> response.set_body(ewe.TextData(id))
        http.Post, ["user"] -> {
          case ewe.read_body(req, 40_000_000) {
            Ok(req) -> {
              let content_type =
                req
                |> request.get_header("content-type")
                |> result.unwrap("application/octet-stream")

              response.new(200)
              |> response.set_body(ewe.BitsData(req.body))
              |> response.prepend_header("content-type", content_type)
            }
            Error(_) -> too_large
          }
        }
        _, _ -> not_found
      }
    }
    |> ewe.new
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
