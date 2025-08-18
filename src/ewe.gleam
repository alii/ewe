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
  State(state: parser.ParsingState)
}

// No public API for now
pub fn start() {
  glisten.new(
    fn(_conn) {
      #(
        parser.ParsingState(
          request: parser.new_request(),
          stage: parser.RequestLine,
          buffer: <<>>,
        ),
        None,
      )
    },
    fn(state, msg, conn) {
      let assert glisten.Packet(msg) = msg

      let current = <<state.buffer:bits, msg:bits>>
      echo current as "buffer"

      let new_state = parser.ParsingState(..state, buffer: current)
      let #(new_state, result) = parser.parse_request(new_state)

      case result {
        Ok(Nil) -> {
          let _ =
            "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!"
            |> bytes_tree.from_string
            |> glisten.send(conn, _)

          glisten.continue(new_state)
        }
        Error(error) -> {
          echo error as "error"

          case error {
            parser.Incomplete -> {
              glisten.continue(new_state)
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
