//// Regression: factory must be alive before glisten accepts connections.
////
//// The old code called glisten.start() eagerly (outside the supervisor),
//// so the port was bound before the factory child existed. A connection
//// arriving in that gap would call factory.start_child on an unregistered
//// name → Noproc crash → OneForAll kills everything → restart loop →
//// supervisor intensity exceeded → permanent death.
////
//// The fix uses glisten.supervised() so the listener starts inside the
//// supervisor, after the factory child is already alive.

import ewe
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/otp/factory_supervisor as factory

@external(erlang, "ewe_test_ffi", "rescue")
fn rescue(f: fn() -> a) -> Result(a, Nil)

/// Prove the failure mode: calling start_child on an unregistered
/// factory name crashes with Noproc. This is exactly what happens
/// when a websocket upgrade arrives before the factory is started.
pub fn unregistered_factory_crashes_test() {
  let bogus_name = process.new_name("nonexistent_factory")
  let supervisor = factory.get_by_name(bogus_name)
  // start_child sends a gen_server:call to the named process.
  // If it doesn't exist → Noproc. This is the crash path.
  let result = rescue(fn() { factory.start_child(supervisor, fn() { panic }) })
  assert result == Error(Nil)
}

/// Prove the fix: after ewe.start() returns, both factory AND
/// glisten are alive. Concurrent requests all succeed.
pub fn factory_alive_after_start_test() {
  let name = process.new_name("ewe_race_fix_test")
  let assert Ok(_) =
    ewe.new(fn(_req) {
      response.new(200) |> response.set_body(ewe.TextData("ok"))
    })
    |> ewe.with_name(name)
    |> ewe.listening_random()
    |> ewe.quiet()
    |> ewe.start()

  let info = ewe.get_server_info(name)
  let ip = ewe.ip_address_to_string(info.ip)
  let port = int.to_string(info.port)
  let url = "http://" <> ip <> ":" <> port <> "/"

  // Fire 20 concurrent requests immediately
  let self = process.new_subject()
  repeat(20, fn() {
    process.spawn(fn() {
      let assert Ok(req) = request.to(url)
      process.send(self, httpc.send(req))
    })
  })

  // All 20 must succeed
  repeat(20, fn() {
    let assert Ok(result) = process.receive(self, 5000)
    let assert Ok(resp) = result
    assert resp.status == 200
  })
}

fn repeat(n: Int, f: fn() -> a) -> Nil {
  case n {
    0 -> Nil
    _ -> {
      f()
      repeat(n - 1, f)
    }
  }
}
