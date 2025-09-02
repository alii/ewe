import gleam/erlang/atom

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

// Represents a file descriptor
pub type IoDevice

// Represents errors that can occur when opening a file
pub type OpenError {
  Enoent
  Eacces
  Eisdir
  Enotdir
  Enospc
}

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Opens a file and returns a file descriptor
pub fn open(path: String) -> Result(IoDevice, OpenError) {
  open_file(path, [atom.create("raw"), atom.create("binary")])
}

// -----------------------------------------------------------------------------
// FILES
// -----------------------------------------------------------------------------

@external(erlang, "file", "open")
fn open_file(path: String, mode: List(atom.Atom)) -> Result(IoDevice, OpenError)
