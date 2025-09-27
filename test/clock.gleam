import ewe/internal/clock
import gleam/float
import gleam/int
import gleam/io
import gleam/list

pub fn main() {
  let iterations = 10_000_000

  clock.get_http_date()

  io.println("Getting HTTP date speed test")

  let begin = now_microseconds()
  let _ =
    list.range(0, iterations)
    |> list.each(fn(_) { clock.get_http_date() })
  let end = now_microseconds()

  let total_duration = end - begin
  let average_nanoseconds =
    { int.to_float(total_duration) *. 1000.0 } /. int.to_float(iterations)

  io.println({
    "Total time for "
    <> int.to_string(iterations)
    <> " iterations: "
    <> int.to_string(total_duration)
    <> " µs (microsecond)"
  })

  {
    "Average time per call: "
    <> float.to_string(average_nanoseconds)
    <> " ns (nanosecond)"
  }
  |> io.println()
}

@external(erlang, "ewe_ffi", "now_microseconds")
fn now_microseconds() -> Int
