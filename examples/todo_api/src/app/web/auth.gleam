import app/jwt
import argus
import ewe.{type Connection, type ResponseBody}
import gleam/bool
import gleam/dynamic/decode
import gleam/http
import gleam/http/cookie
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option
import gleam/result
import gleam/time/duration
import pog

import app/web.{type Context, unexpected_message}
import app/web/auth/sql

fn credentials_decoder() -> decode.Decoder(#(String, String)) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(#(username, password))
}

pub fn register(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseBody) {
  use <- web.require_method(req, http.Post)
  use #(username, password) <- web.require_json(req, credentials_decoder)

  use <- ewe.use_expression()

  use hashes <- result.try(
    argus.hasher()
    |> argus.algorithm(argus.Argon2id)
    |> argus.time_cost(3)
    |> argus.memory_cost(12_228)
    |> argus.parallelism(1)
    |> argus.hash_length(32)
    |> argus.hash(password, argus.gen_salt())
    |> result.map_error(web.internal("error in hashing password", _)),
  )

  case sql.create_user(ctx.db, username, hashes.encoded_hash) {
    Ok(pog.Returned(count: 1, rows: _)) ->
      response.new(201)
      |> web.json_body(web.OkMessage("User created"))
      |> Ok
    Error(pog.ConstraintViolated(..)) ->
      response.new(409)
      |> web.json_body(web.ErrorMessage("User already exists"))
      |> Ok

    Error(issue) -> Error(web.internal("error in create_user", issue))
    Ok(never) -> Error(web.internal(unexpected_message("create_user"), never))
  }
}

pub fn login(req: Request(Connection), ctx: Context) -> Response(ResponseBody) {
  use <- web.require_method(req, http.Post)
  use #(username, password) <- web.require_json(req, credentials_decoder)

  use <- ewe.use_expression()

  use user <- result.try(case sql.find_user_by_username(ctx.db, username) {
    Ok(pog.Returned(count: 1, rows: [user])) -> Ok(user)
    Ok(pog.Returned(count: 0, rows: [])) ->
      response.new(401)
      |> web.json_body(web.ErrorMessage("Invalid username or password"))
      |> Error

    Error(issue) -> Error(web.internal("error in find_user_by_username", issue))
    Ok(never) ->
      Error(web.internal(unexpected_message("find_user_by_username"), never))
  })

  use verified <- result.try(
    argus.verify(user.password_hash, password)
    |> result.map_error(web.internal("error in verifying password", _)),
  )

  use <- bool.guard(
    when: !verified,
    return: response.new(401)
      |> web.json_body(web.ErrorMessage("Invalid username or password"))
      |> Error,
  )

  let token =
    jwt.sign_token(
      expires_after: duration.hours(24),
      claims: jwt.new_claims(user.id, user.username),
      secret: ctx.jwt_secret,
    )

  let cookie_attrs =
    cookie.Attributes(
      ..cookie.defaults(req.scheme),
      max_age: option.Some(60 * 60 * 24),
    )

  response.new(200)
  |> web.json_body(web.OkMessage("Login successful"))
  |> response.set_cookie("session", token, cookie_attrs)
  |> Ok
}

pub fn delete(req: Request(Connection), ctx: Context) -> Response(ResponseBody) {
  use <- web.require_method(req, http.Post)
  use #(username, password) <- web.require_json(req, credentials_decoder)

  use <- ewe.use_expression()

  use user <- result.try(case sql.find_user_by_username(ctx.db, username) {
    Ok(pog.Returned(count: 1, rows: [user])) -> Ok(user)
    Ok(pog.Returned(count: 0, rows: [])) ->
      response.new(401)
      |> web.json_body(web.ErrorMessage("Invalid username or password"))
      |> Error

    Error(issue) -> Error(web.internal("error in find_user_by_username", issue))
    Ok(never) ->
      Error(web.internal(unexpected_message("find_user_by_username"), never))
  })

  use verified <- result.try(
    argus.verify(user.password_hash, password)
    |> result.map_error(web.internal("error in verifying password", _)),
  )

  use <- bool.guard(
    when: !verified,
    return: response.new(401)
      |> web.json_body(web.ErrorMessage("Invalid username or password"))
      |> Error,
  )

  case sql.delete_user(ctx.db, user.id) {
    Ok(_) ->
      response.new(200)
      |> web.json_body(web.OkMessage("User deleted"))
      |> Ok
    Error(issue) -> Error(web.internal("error in delete_user", issue))
  }
}

pub fn logout(req: Request(Connection)) -> Response(ResponseBody) {
  use <- web.require_method(req, http.Post)

  let cookie_attrs =
    cookie.Attributes(..cookie.defaults(req.scheme), max_age: option.Some(0))

  response.new(200)
  |> web.json_body(web.OkMessage("Logout successful"))
  |> response.set_cookie("session", "", cookie_attrs)
}

pub fn session(req: Request(Connection), ctx: Context) -> Response(ResponseBody) {
  use <- web.require_method(req, http.Get)
  use claims <- web.auth_middleware(req, ctx)

  let json =
    json.object([
      #("id", json.int(claims.user_id)),
      #("username", json.string(claims.username)),
    ])

  response.new(200)
  |> web.json_body(web.Custom(json))
}
