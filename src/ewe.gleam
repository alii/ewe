import ewe/internal/parser
import ewe/internal/response as ewe_response
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import glisten

pub opaque type Builder {
  Builder(
    handler: fn(request.Request(BitArray)) ->
      response.Response(bytes_tree.BytesTree),
    port: Int,
  )
}

pub fn new(
  handler: fn(request.Request(BitArray)) ->
    response.Response(bytes_tree.BytesTree),
) -> Builder {
  Builder(handler: handler, port: 8080)
}

pub fn port(builder: Builder, port: Int) -> Builder {
  Builder(..builder, port:)
}

pub fn start(
  builder: Builder,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  glisten.new(fn(_conn) { #(parser.new_parser(), None) }, fn(parser, msg, conn) {
    let assert glisten.Packet(msg) = msg
    let parser =
      parser.Parser(..parser, buffer: <<parser.buffer:bits, msg:bits>>)

    case parser.parse_request(parser) {
      Ok(request) -> {
        let send =
          builder.handler(request)
          |> ewe_response.encode()
          |> glisten.send(conn, _)

        case send {
          Ok(Nil) -> glisten.continue(parser.new_parser())
          Error(_) -> glisten.stop()
        }
      }
      Error(parser.Incomplete(parser)) -> glisten.continue(parser)
      Error(_) -> glisten.stop()
    }
  })
  |> glisten.bind("0.0.0.0")
  |> glisten.start(builder.port)
}
