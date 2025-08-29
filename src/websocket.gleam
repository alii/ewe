import ewe
import gleam/erlang/process

pub fn main() {
  ewe.new(fn(req) { ewe.upgrade_websocket(req) })
  |> ewe.with_port(42_072)
  |> ewe.bind_all()
  |> ewe.with_ipv6()
  |> ewe.start()

  process.sleep_forever()
}
