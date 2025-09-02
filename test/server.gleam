import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/result

import ewe

pub fn hi() {
  ewe.new(fn(_req) { response.new(200) |> ewe.text("hi") })
}

pub fn echoer() {
  ewe.new(fn(req) {
    let content_type =
      request.get_header(req, "content-type")
      |> result.unwrap("text/plain")

    use <- ewe.use_expression()

    use req <- result.try(
      ewe.read_body(req, 1024)
      |> result.replace_error(ewe.empty(response.new(400))),
    )

    response.new(200)
    |> ewe.bits(req.body)
    |> response.set_header("content-type", content_type)
    |> Ok
  })
}

pub fn start(builder: ewe.Builder(ewe.Connection)) {
  let name = process.new_name("ewe_test_server")

  let _ =
    ewe.set_information_name(builder, name)
    |> ewe.listening_random()
    |> ewe.quiet()
    |> ewe.start()

  let assert Ok(server_info) = ewe.get_server_info(name)

  server_info
}
