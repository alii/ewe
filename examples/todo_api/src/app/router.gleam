import ewe.{type Connection, type ResponseBody}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

import app/web.{type Context}
import app/web/auth
import app/web/task

pub fn handle_request(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseBody) {
  case request.path_segments(req) {
    ["auth", "login"] -> auth.login(req, ctx)
    ["auth", "register"] -> auth.register(req, ctx)
    ["auth", "logout"] -> auth.logout(req)
    ["auth", "delete"] -> auth.delete(req, ctx)

    ["session"] -> auth.session(req, ctx)

    ["tasks"] -> task.all(req, ctx)
    ["tasks", id] -> task.one(req, ctx, id)

    _ ->
      web.ErrorMessage("Unknown endpoint")
      |> web.json_body(response.new(404), _)
  }
}
