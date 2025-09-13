import app
import envoy
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleeunit

pub fn main() -> Nil {
  case app.start_app_supervisor(process.new_name("pog_pool")) {
    Ok(_) -> gleeunit.main()
    Error(_) -> io.println_error("Failed to start app supervisor")
  }
}

pub fn make_request(
  method method: http.Method,
  path path: String,
  body body: Option(String),
  session session: Option(String),
) -> request.Request(String) {
  let assert Ok(port) = envoy.get("APP_PORT")
  let assert Ok(req) = request.to("http://localhost:" <> port <> path)

  let req = request.set_method(req, method)

  let req = case body {
    None -> req
    Some(body) ->
      request.set_body(req, body)
      |> request.set_header("content-type", "application/json")
  }

  case session {
    None -> req
    Some(session) -> request.set_cookie(req, "session", session)
  }
}

// pub fn clear_user

pub fn request_test() {
  let body =
    json.object([
      #("username", json.string("test")),
      #("password", json.string("test")),
    ])
    |> json.to_string()

  let req =
    make_request(
      method: http.Post,
      path: "/auth/register",
      body: Some(body),
      session: None,
    )
  let assert Ok(resp) = httpc.send(req)

  echo resp
}
