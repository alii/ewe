// NOTE: targetting RFCs:
// - https://datatracker.ietf.org/doc/html/rfc9110
// core HTTP semantics like methods and required headers
// - https://datatracker.ietf.org/doc/html/rfc9112
// HTTP/1.1-specific message syntax, parsing rules, connection details

import gleam/bytes_tree
import gleam/erlang/process
import gleam/option.{None}
import glisten
import internal/parser

// NOTE: will be removed once we have a public API
pub fn main() -> Nil {
  let assert Ok(_) = start(port: 42_069)

  process.sleep_forever()
}

pub type State {
  State(buffer: BitArray, parser: parser.ParsingState)
}

// No public API for now
pub fn start(port port: Int) {
  glisten.new(
    fn(_conn) { #(State(<<>>, parser.new_state()), None) },
    fn(state, msg, conn) {
      let assert glisten.Packet(msg) = msg
      let buffer = <<state.buffer:bits, msg:bits>>

      case parser.parse_request(state.parser, buffer) {
        Ok(request) -> {
          echo request as "request parsed!"
          let _ =
            <<"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!">>
            |> bytes_tree.from_bit_array
            |> glisten.send(conn, _)
          // |> echo

          glisten.stop()
        }
        Error(#(parser, buffer, error)) -> {
          // echo #(buffer, error) as "error"

          case error {
            parser.Incomplete -> {
              glisten.continue(State(buffer:, parser:))
            }
            _ -> {
              glisten.stop()
            }
          }
        }
      }
    },
  )
  |> glisten.bind("0.0.0.0")
  |> glisten.start(port)
}
