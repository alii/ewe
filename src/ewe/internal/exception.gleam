// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/dynamic

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

// Represents an exception happened during the call
pub type Exception {
  Errored(dynamic.Dynamic)
  Thrown(dynamic.Dynamic)
  Exited(dynamic.Dynamic)
}

// -----------------------------------------------------------------------------
// RESCUE
// -----------------------------------------------------------------------------

/// Rescues an exception that happened during the call
@external(erlang, "ewe_ffi", "rescue")
pub fn rescue(callable: fn() -> a) -> Result(a, Exception)
