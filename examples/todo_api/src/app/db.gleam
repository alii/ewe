import cigogne
import cigogne/types
import envoy
import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/otp/supervision
import gleam/result
import pog

pub fn create_pog_pool_child(
  pool_name: process.Name(pog.Message),
) -> supervision.ChildSpecification(pog.Connection) {
  let assert Ok(pg_database) = envoy.get("PG_DATABASE")
  let assert Ok(pg_user) = envoy.get("PG_USER")
  let assert Ok(pg_password) = envoy.get("PG_PASSWORD")
  let assert Ok(pg_host) = envoy.get("PG_HOST")
  let assert Ok(pg_port_string) = envoy.get("PG_PORT")
  let assert Ok(pg_port) = int.parse(pg_port_string)

  pog.default_config(pool_name:)
  |> pog.database(pg_database)
  |> pog.user(pg_user)
  |> pog.password(option.Some(pg_password))
  |> pog.host(pg_host)
  |> pog.port(pg_port)
  |> pog.pool_size(10)
  |> pog.supervised()
}

pub fn migrate() -> Result(Nil, types.MigrateError) {
  let config = cigogne.default_config

  use engine <- result.try(cigogne.create_engine(config))

  let migrate = cigogne.apply_to_last(engine)
  case migrate {
    Error(types.NoMigrationToApplyError) -> Ok(Nil)
    _ -> migrate
  }
}
