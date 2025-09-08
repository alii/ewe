//// This module contains the code to run the sql queries defined in
//// `./src/app/web/task/sql`.
//// > 🐿️ This module was generated automatically using v4.4.1 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import pog

/// A row you get from running the `create_task` query
/// defined in `./src/app/web/task/sql/create_task.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.4.1 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CreateTaskRow {
  CreateTaskRow(id: Int, title: String, description: String, completed: Bool)
}

/// Runs the `create_task` query
/// defined in `./src/app/web/task/sql/create_task.sql`.
///
/// > 🐿️ This function was generated automatically using v4.4.1 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn create_task(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: Bool,
  arg_4: Int,
) -> Result(pog.Returned(CreateTaskRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use completed <- decode.field(3, decode.bool)
    decode.success(CreateTaskRow(id:, title:, description:, completed:))
  }

  "insert into
tasks (title, description, completed, user_id)
values ($1, $2, $3, $4)
returning id, title, description, completed;"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.bool(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `delete_task` query
/// defined in `./src/app/web/task/sql/delete_task.sql`.
///
/// > 🐿️ This function was generated automatically using v4.4.1 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_task(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "delete
from tasks
where id = $1;"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `get_task` query
/// defined in `./src/app/web/task/sql/get_task.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.4.1 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetTaskRow {
  GetTaskRow(id: Int, title: String, description: String, completed: Bool)
}

/// Runs the `get_task` query
/// defined in `./src/app/web/task/sql/get_task.sql`.
///
/// > 🐿️ This function was generated automatically using v4.4.1 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_task(
  db: pog.Connection,
  arg_1: Int,
  arg_2: Int,
) -> Result(pog.Returned(GetTaskRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use completed <- decode.field(3, decode.bool)
    decode.success(GetTaskRow(id:, title:, description:, completed:))
  }

  "select id, title, description, completed
from tasks
where id = $1 and user_id = $2;"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_completed_tasks` query
/// defined in `./src/app/web/task/sql/list_completed_tasks.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.4.1 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListCompletedTasksRow {
  ListCompletedTasksRow(
    id: Int,
    title: String,
    description: String,
    completed: Bool,
  )
}

/// Runs the `list_completed_tasks` query
/// defined in `./src/app/web/task/sql/list_completed_tasks.sql`.
///
/// > 🐿️ This function was generated automatically using v4.4.1 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_completed_tasks(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(ListCompletedTasksRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use completed <- decode.field(3, decode.bool)
    decode.success(ListCompletedTasksRow(id:, title:, description:, completed:))
  }

  "select id, title, description, completed
from tasks
where user_id = $1 and completed = true;"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_tasks` query
/// defined in `./src/app/web/task/sql/list_tasks.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.4.1 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListTasksRow {
  ListTasksRow(id: Int, title: String, description: String, completed: Bool)
}

/// Runs the `list_tasks` query
/// defined in `./src/app/web/task/sql/list_tasks.sql`.
///
/// > 🐿️ This function was generated automatically using v4.4.1 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_tasks(
  db: pog.Connection,
  arg_1: Int,
) -> Result(pog.Returned(ListTasksRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use completed <- decode.field(3, decode.bool)
    decode.success(ListTasksRow(id:, title:, description:, completed:))
  }

  "select id, title, description, completed
from tasks
where user_id = $1;"
  |> pog.query
  |> pog.parameter(pog.int(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `update_task` query
/// defined in `./src/app/web/task/sql/update_task.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.4.1 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type UpdateTaskRow {
  UpdateTaskRow(id: Int, title: String, description: String, completed: Bool)
}

/// Runs the `update_task` query
/// defined in `./src/app/web/task/sql/update_task.sql`.
///
/// > 🐿️ This function was generated automatically using v4.4.1 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn update_task(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: Bool,
  arg_4: Int,
  arg_5: Int,
) -> Result(pog.Returned(UpdateTaskRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    use title <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use completed <- decode.field(3, decode.bool)
    decode.success(UpdateTaskRow(id:, title:, description:, completed:))
  }

  "update
tasks
set title = $1, description = $2, completed = $3
where id = $4 and user_id = $5
returning id, title, description, completed;"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.bool(arg_3))
  |> pog.parameter(pog.int(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
