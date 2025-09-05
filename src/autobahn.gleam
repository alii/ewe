import ewe
import gleam/erlang/process
import gleam/io

pub fn main() -> Nil {
  let assert Ok(_) =
    ewe.new(fn(req) {
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) { #(Nil, selector) },
        handler: fn(conn, state, msg) {
          echo msg
          case msg {
            ewe.Text(text_frame) -> {
              let _ = ewe.send_text_frame(conn, text_frame)
              ewe.continue(state)
            }
            ewe.Binary(binary_frame) -> {
              let _ = ewe.send_binary_frame(conn, binary_frame)
              ewe.continue(state)
            }
            _ -> ewe.continue(state)
          }
        },
        on_close: fn(_conn, _state) { Nil },
      )
    })
    |> ewe.enable_ipv6()
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
