import ewe
import gleam/erlang/process

pub fn main() {
  let assert Ok(_) =
    ewe.new(fn(req) {
      ewe.upgrade_websocket(req, fn(msg) {
        echo msg as "handler received:"

        ewe.continue()
      })
    })
    |> ewe.with_port(42_069)
    |> ewe.bind_all()
    |> ewe.start()

  process.sleep_forever()
}
