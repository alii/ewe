import ewe
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import logging

pub fn main() -> Nil {
  logging.configure()
  logging.set_level(logging.Info)

  // spectator.start()

  let ewe_server =
    ewe.new(fn(req) {
      ewe.upgrade_websocket(
        req,
        on_init: fn(_conn, selector) { #(Nil, selector) },
        handler: fn(conn, state, msg) {
          case msg {
            ewe.Text(text_frame) -> {
              let _ = ewe.send_text_frame(conn, text_frame)
              ewe.websocket_continue(state)
            }
            ewe.Binary(binary_frame) -> {
              let _ = ewe.send_binary_frame(conn, binary_frame)
              ewe.websocket_continue(state)
            }
            _ -> ewe.websocket_continue(state)
          }
        },
        on_close: fn(_conn, _state) { Nil },
      )
    })
    |> ewe.enable_ipv6()
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.supervised()

  let assert Ok(_) =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(ewe_server)
    |> supervisor.restart_tolerance(intensity: 1_000_000, period: 1_000_000)
    |> supervisor.start()

  process.sleep_forever()
}
