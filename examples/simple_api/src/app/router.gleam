import ewe.{type Connection, type ResponseBody}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

import app/web.{type Context}
import app/web/auth

pub fn handle_request(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseBody) {
  case request.path_segments(req) {
    ["auth", "login"] -> auth.login(req, ctx)
    ["auth", "register"] -> auth.register(req, ctx)
    ["auth", "logout"] -> auth.logout(req)
    ["session"] -> auth.session(req, ctx)

    // TODO: add tasks routes
    ["tasks"] -> todo
    _ -> ewe.empty(response.new(404))
  }
}
