import ewe.{type Connection, type ResponseBody}
import gleam/bool
import gleam/dynamic/decode
import gleam/function
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import pog

import app/web.{type Context, unexpected_message}
import app/web/task/sql

fn task_decoder() -> decode.Decoder(#(String, String, Bool)) {
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use completed <- decode.optional_field("completed", False, decode.bool)
  decode.success(#(title, description, completed))
}

fn optional_task_decoder() -> decode.Decoder(
  #(Option(String), Option(String), Option(Bool)),
) {
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use completed <- decode.optional_field(
    "completed",
    None,
    decode.optional(decode.bool),
  )
  decode.success(#(title, description, completed))
}

pub fn all(req: Request(Connection), ctx: Context) -> Response(ResponseBody) {
  case req.method {
    http.Get -> list_tasks(req, ctx)
    http.Post -> create_task(req, ctx)
    _ -> web.method_not_allowed([http.Get, http.Post])
  }
}

pub fn one(
  req: Request(Connection),
  ctx: Context,
  id: String,
) -> Response(ResponseBody) {
  case int.parse(id) {
    Ok(id) -> {
      case req.method {
        http.Put -> update_task(req, ctx, id)
        http.Delete -> delete_task(req, ctx, id)
        _ -> web.method_not_allowed([http.Put, http.Delete])
      }
    }
    Error(_) ->
      response.new(400)
      |> web.json_body(web.ErrorMessage("Invalid ID"))
  }
}

pub fn list_tasks(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseBody) {
  use claims <- web.auth_middleware(req, ctx)

  let query_completed = case request.get_query(req) {
    Ok(query) -> {
      case list.key_find(query, "completed") {
        Ok(_completed) -> True
        Error(Nil) -> False
      }
    }
    Error(Nil) -> False
  }

  case query_completed {
    True ->
      case sql.list_completed_tasks(ctx.db, claims.user_id) {
        Ok(pog.Returned(rows: tasks, ..)) -> {
          list.map(tasks, fn(task) {
            json.object([
              #("id", json.int(task.id)),
              #("title", json.string(task.title)),
              #("description", json.string(task.description)),
              #("completed", json.bool(task.completed)),
            ])
          })
          |> json.array(of: function.identity)
          |> web.Custom
          |> web.json_body(response.new(200), _)
        }
        Error(issue) -> web.internal("error in list_completed_tasks", issue)
      }
    False ->
      case sql.list_tasks(ctx.db, claims.user_id) {
        Ok(pog.Returned(rows: tasks, ..)) -> {
          list.map(tasks, fn(task) {
            json.object([
              #("id", json.int(task.id)),
              #("title", json.string(task.title)),
              #("description", json.string(task.description)),
              #("completed", json.bool(task.completed)),
            ])
          })
          |> json.array(of: function.identity)
          |> web.Custom
          |> web.json_body(response.new(200), _)
        }
        Error(issue) -> web.internal("error in list_tasks", issue)
      }
  }
}

pub fn create_task(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseBody) {
  use claims <- web.auth_middleware(req, ctx)

  use #(title, description, completed) <- web.require_json(req, task_decoder)

  case sql.create_task(ctx.db, title, description, completed, claims.user_id) {
    Ok(pog.Returned(count: 1, rows: [task])) -> {
      json.object([
        #("id", json.int(task.id)),
        #("title", json.string(task.title)),
        #("description", json.string(task.description)),
        #("completed", json.bool(task.completed)),
      ])
      |> web.Custom
      |> web.json_body(response.new(201), _)
    }
    Error(issue) -> web.internal("error in create_task", issue)
    Ok(never) -> web.internal(unexpected_message("create_task"), never)
  }
}

pub fn update_task(
  req: Request(Connection),
  ctx: Context,
  id: Int,
) -> Response(ResponseBody) {
  use claims <- web.auth_middleware(req, ctx)
  use #(title, description, completed) <- web.require_json(
    req,
    optional_task_decoder,
  )

  use <- ewe.use_expression()

  use task <- result.try(case sql.get_task(ctx.db, id) {
    Ok(pog.Returned(count: 1, rows: [task])) -> {
      Ok(task)
    }
    Ok(pog.Returned(count: 0, rows: [])) -> {
      response.new(404)
      |> web.json_body(web.ErrorMessage("Task not found"))
      |> Error
    }
    Error(issue) -> Error(web.internal("error in get_task", issue))
    Ok(never) -> Error(web.internal(unexpected_message("get_task"), never))
  })

  use <- bool.guard(
    when: task.user_id != claims.user_id,
    return: Error(web.forbidden()),
  )

  let update =
    sql.update_task(
      ctx.db,
      option.unwrap(title, task.title),
      option.unwrap(description, task.description),
      option.unwrap(completed, task.completed),
      id,
      claims.user_id,
    )

  case update {
    Ok(pog.Returned(count: 1, rows: [task])) -> {
      json.object([
        #("id", json.int(task.id)),
        #("title", json.string(task.title)),
        #("description", json.string(task.description)),
        #("completed", json.bool(task.completed)),
      ])
      |> web.Custom
      |> web.json_body(response.new(200), _)
      |> Ok
    }
    Error(issue) -> Error(web.internal("error in update_task", issue))
    Ok(never) -> Error(web.internal(unexpected_message("update_task"), never))
  }
}

pub fn delete_task(
  req: Request(Connection),
  ctx: Context,
  id: Int,
) -> Response(ResponseBody) {
  use claims <- web.auth_middleware(req, ctx)

  use <- ewe.use_expression()

  use task <- result.try(case sql.get_task(ctx.db, id) {
    Ok(pog.Returned(count: 1, rows: [task])) -> Ok(task)
    Ok(pog.Returned(count: 0, rows: [])) ->
      response.new(404)
      |> web.json_body(web.ErrorMessage("Task not found"))
      |> Error
    Error(issue) -> Error(web.internal("error in get_task", issue))
    Ok(never) -> Error(web.internal(unexpected_message("get_task"), never))
  })

  use <- bool.guard(
    when: task.user_id != claims.user_id,
    return: Error(web.forbidden()),
  )

  case sql.delete_task(ctx.db, id) {
    Ok(_) ->
      response.new(200)
      |> web.json_body(web.OkMessage("Task deleted"))
      |> Ok
    Error(issue) -> Error(web.internal("error in delete_task", issue))
  }
}
