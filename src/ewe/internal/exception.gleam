import gleam/dynamic

pub type Exception {
  Errored(dynamic.Dynamic)
  Thrown(dynamic.Dynamic)
  Exited(dynamic.Dynamic)
}

@external(erlang, "ewe_ffi", "rescue")
pub fn rescue(callable: fn() -> a) -> Result(a, Exception)
