import gleam/erlang/atom

pub type IoDevice

pub type OpenError {
  Enoent
  Eacces
  Eisdir
  Enotdir
  Enospc
}

pub fn open(path: String) -> Result(IoDevice, OpenError) {
  open_file(path, [atom.create("raw"), atom.create("binary")])
}

@external(erlang, "file", "open")
fn open_file(path: String, mode: List(atom.Atom)) -> Result(IoDevice, OpenError)
