import app/jwt
import ewe.{type Connection, type ResponseBody}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import pog

pub type Context {
  Context(db: pog.Connection, jwt_secret: String)
}

pub fn auth_middleware(
  req: Request(Connection),
  ctx: Context,
  next: fn(jwt.Claims) -> Response(ResponseBody),
) -> Response(ResponseBody) {
  request.get_cookies(req)
  |> list.key_find("session")
  |> result.try(fn(session) {
    case jwt.verify_token(session, ctx.jwt_secret) {
      Ok(claims) -> Ok(next(claims))
      Error(_) -> Error(Nil)
    }
  })
  |> result.unwrap(unauthorized())
}

pub type JsonBody {
  OkMessage(String)
  ErrorMessage(String)
  Custom(json.Json)
}

pub fn json_body(resp: Response(a), body: JsonBody) -> Response(ResponseBody) {
  case body {
    OkMessage(message) -> json.object([#("message", json.string(message))])
    ErrorMessage(message) -> json.object([#("error", json.string(message))])
    Custom(json) -> json
  }
  |> json.to_string_tree()
  |> ewe.json(resp, _)
}

pub fn invalid_body() -> Response(ResponseBody) {
  response.new(400)
  |> json_body(ErrorMessage("Invalid body"))
}

pub fn unauthorized() -> Response(ResponseBody) {
  response.new(401)
  |> json_body(ErrorMessage("Unauthorized"))
}

pub fn forbidden() -> Response(ResponseBody) {
  response.new(403)
  |> json_body(ErrorMessage("Action not allowed on a not owned task"))
}

pub fn method_not_allowed(method: List(http.Method)) -> Response(ResponseBody) {
  let method =
    list.map(method, http.method_to_string)
    |> list.sort(string.compare)
    |> string.join(", ")

  response.new(405)
  |> response.set_header("allow", method)
  |> json_body(ErrorMessage("Method not allowed"))
}

pub fn body_too_large() -> Response(ResponseBody) {
  response.new(413)
  |> json_body(ErrorMessage("Body too large"))
}

pub fn unsupported_media_type() -> Response(ResponseBody) {
  response.new(415)
  |> response.set_header("accept", "application/json")
  |> json_body(ErrorMessage("Unsupported media type"))
}

pub fn internal(message: String, error: any) -> Response(ResponseBody) {
  echo #(message, error) as "Internal Server Error:"

  response.new(500)
  |> json_body(ErrorMessage("Internal server error"))
}

pub fn require_method(
  req: Request(Connection),
  method: http.Method,
  next: fn() -> Response(ResponseBody),
) -> Response(ResponseBody) {
  case req.method == method {
    True -> next()
    False -> method_not_allowed([method])
  }
}

pub fn require_json(
  req: Request(Connection),
  decoder: fn() -> decode.Decoder(a),
  next: fn(a) -> Response(ResponseBody),
) -> Response(ResponseBody) {
  use <- ewe.use_expression()

  use _ <- result.try(case list.key_find(req.headers, "content-type") {
    Ok(content_type) -> {
      case string.split_once(content_type, ";") {
        Ok(#(media_type, _)) if media_type == "application/json" -> Ok(Nil)
        _ if content_type == "application/json" -> Ok(Nil)
        _ -> Error(unsupported_media_type())
      }
    }
    Error(Nil) -> Error(unsupported_media_type())
  })

  use body <- result.try(case ewe.read_body(req, 500_000) {
    Ok(req) -> Ok(req.body)
    Error(ewe.BodyTooLarge) -> Error(body_too_large())
    Error(ewe.InvalidBody) -> Error(invalid_body())
  })

  case json.parse_bits(body, decoder()) {
    Ok(value) -> Ok(next(value))
    Error(_) -> Error(invalid_body())
  }
}

pub fn unexpected_message(fn_name: String) -> String {
  "unexpected return from " <> fn_name
}
