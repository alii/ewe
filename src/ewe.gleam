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
  let assert Ok(_) = start()

  process.sleep_forever()
}

pub type State {
  State(buffer: BitArray, parser: parser.ParsingState)
}

// No public API for now
pub fn start() {
  glisten.new(
    fn(_conn) { #(State(<<>>, parser.new_state()), None) },
    fn(state, msg, conn) {
      let assert glisten.Packet(msg) = msg
      let buffer = <<state.buffer:bits, msg:bits>>
      echo buffer

      case parser.parse_request(state.parser, buffer) {
        Ok(request) -> {
          echo request as "request parsed!"
          let _ =
            <<"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!">>
            |> bytes_tree.from_bit_array
            |> glisten.send(conn, _)
            |> echo

          glisten.stop()
        }
        Error(#(parser, buffer, error)) -> {
          echo #(buffer, error) as "error"

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
      // NOTE: parsing received messages from buffer, if it's ewww then
      // continue until we have a full message ??? Else, we will put the
      // parsed request as argument of handler.

      // And theeeen we can figure out what to do next

      // hard coded response for now
      // let _ =
      //   "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!"
      //   |> bytes_tree.from_string
      //   |> glisten.send(conn, _)
    },
  )
  |> glisten.bind("0.0.0.0")
  |> glisten.start(42_069)
}
