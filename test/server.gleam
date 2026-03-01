import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/result

import ewe

pub fn start(builder: ewe.Builder) -> ewe.SocketAddress {
  let name = process.new_name("ewe_test_server")

  let _ =
    ewe.with_name(builder, name)
    |> ewe.listening_random()
    |> ewe.quiet()
    |> ewe.start()

  ewe.get_server_info(name)
}

pub fn hi() -> ewe.Builder {
  ewe.new(fn(_req) {
    response.new(200)
    |> response.set_body(ewe.TextData("hi"))
    |> response.set_header("content-type", "text/plain; charset=utf-8")
  })
}

pub fn echoer() -> ewe.Builder {
  ewe.new(fn(req) {
    let content_type =
      request.get_header(req, "content-type")
      |> result.unwrap("text/plain")

    case ewe.read_body(req, 10_240) {
      Ok(req) -> {
        response.new(200)
        |> response.set_body(ewe.BitsData(req.body))
        |> response.set_header("content-type", content_type)
      }
      Error(_) -> response.new(400) |> response.set_body(ewe.Empty)
    }
  })
}
