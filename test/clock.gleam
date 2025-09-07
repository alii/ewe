import ewe/internal/clock
import gleam/float
import gleam/int
import gleam/list

pub fn main() {
  let iterations = 10_000_000
  clock.get_http_date()

  let begin = now_microseconds()
  let _ =
    list.range(0, iterations)
    |> list.each(fn(_) { clock.get_http_date() })
  let end = now_microseconds()

  let total_duration = end - begin
  let average_nanoseconds =
    { int.to_float(total_duration) *. 1000.0 } /. int.to_float(iterations)

  echo "Total time for "
    <> int.to_string(iterations)
    <> " iterations: "
    <> int.to_string(total_duration)
    <> " µs"
  echo "Average time per call: "
    <> float.to_string(average_nanoseconds)
    <> " ns"
}

@external(erlang, "ewe_ffi", "now_microseconds")
fn now_microseconds() -> Int
