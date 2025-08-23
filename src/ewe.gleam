import ewe/internal/http as http_
import ewe/internal/response as ewe_response
import gleam/http/request.{type Request}
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import glisten

pub type Connection =
  http_.Connection

pub opaque type Builder {
  Builder(handler: http_.Handler, port: Int)
}

pub fn new(handler: http_.Handler) -> Builder {
  Builder(handler: handler, port: 8080)
}

pub fn port(builder: Builder, port: Int) -> Builder {
  Builder(..builder, port:)
}

pub fn start(
  builder: Builder,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  glisten.new(
    fn(conn) { #(http_.transform_connection(conn), None) },
    fn(http_conn, msg, conn) {
      let assert glisten.Packet(msg) = msg
      case http_.parse_request(http_conn, msg) {
        Ok(req) -> {
          let send =
            builder.handler(req)
            |> ewe_response.encode()
            |> glisten.send(conn, _)

          case send {
            Ok(Nil) -> glisten.continue(http_conn)
            Error(_) -> glisten.stop()
          }
        }
        Error(_) -> glisten.stop()
      }
    },
  )
  |> glisten.bind("0.0.0.0")
  |> glisten.start(builder.port)
}

pub fn read_body(req: Request(Connection)) -> Result(Request(BitArray), Nil) {
  http_.read_body(req) |> result.replace_error(Nil)
}
