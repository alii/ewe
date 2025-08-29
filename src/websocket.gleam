import ewe
import ewe/internal/websocket as websocket_
import gleam/erlang/process

pub fn main() {
  let _ =
    ewe.new(fn(req) {
      ewe.upgrade_websocket(req, fn(frame) {
        echo frame

        websocket_.Continue
      })
    })
    |> ewe.with_port(42_072)
    |> ewe.bind_all()
    |> ewe.with_ipv6()
    |> ewe.start()

  process.sleep_forever()
}
