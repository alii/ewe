import envoy
import ewe
import gleam/erlang/process
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import pog

import app/db
import app/router
import app/web

pub fn main() -> Nil {
  let db_pool = process.new_name("pog_pool")

  let assert Ok(_) = db.migrate()
  let assert Ok(_) = start_app_supervisor(db_pool)

  process.sleep_forever()
}

fn start_app_supervisor(
  pool_name: process.Name(pog.Message),
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let pool_child = db.create_pog_pool_child(pool_name)
  let server_child = create_server_child(pool_name)

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(pool_child)
  |> supervisor.add(server_child)
  |> supervisor.start()
}

fn create_server_child(
  pool_name: process.Name(pog.Message),
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  let assert Ok(port) = envoy.get("APP_PORT") |> result.try(int.parse)
  let assert Ok(jwt_secret) = envoy.get("JWT_SECRET")

  let conn = pog.named_connection(pool_name)
  let ctx = web.Context(db: conn, jwt_secret:)

  ewe.new(router.handle_request(_, ctx))
  |> ewe.bind_all()
  |> ewe.listening(port:)
  |> ewe.supervised()
}
