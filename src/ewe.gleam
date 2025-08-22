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

// No public API for now
pub fn start(port port: Int) {
  glisten.new(fn(_conn) { #(parser.new_parser(), None) }, fn(state, msg, conn) {
    let assert glisten.Packet(msg) = msg
    let parser = parser.Parser(..state, buffer: <<state.buffer:bits, msg:bits>>)

    case parser.parse_request(parser) {
      Ok(_request) -> {
        let response = <<
          "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, world!",
        >>

        let _ =
          response
          |> bytes_tree.from_bit_array
          |> glisten.send(conn, _)

        glisten.continue(parser.new_parser())
      }
      Error(error) -> {
        case error {
          parser.Incomplete(parser) -> glisten.continue(parser)
          parser.Invalid -> {
            let _ =
              glisten.send(
                conn,
                <<"HTTP/1.1 400 Bad Request\r\n\r\n">>
                  |> bytes_tree.from_bit_array,
              )
            glisten.stop()
          }
          parser.TooLarge -> {
            echo "Too large"
            glisten.stop()
          }
          _ -> glisten.stop()
        }
      }
    }
  })
  |> glisten.bind("0.0.0.0")
  |> glisten.start(port)
}
