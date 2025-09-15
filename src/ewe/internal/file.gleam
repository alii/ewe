import gleam/bytes_tree
import gleam/dynamic
import gleam/result
import glisten
import glisten/socket.{type Socket}
import glisten/transport.{type Transport}

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

// Represents a reference to a file
pub type IoDevice

// Represents errors that can occur when opening a file
pub type FileError {
  Enoent
  Eacces
  Eisdir
  Eunknown(dynamic.Dynamic)
}

pub type File {
  File(descriptor: IoDevice, size: Int)
}

pub type SendError {
  FileIssue(FileError)
  SocketIssue(glisten.SocketReason)
}

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

pub fn send(
  transport: Transport,
  socket: Socket,
  descriptor: IoDevice,
  offset: Int,
  size: Int,
) -> Result(Nil, SendError) {
  case transport {
    transport.Tcp(..) -> {
      send_file(descriptor, socket, offset, size, [])
      |> result.map_error(SocketIssue)
    }
    transport.Ssl(..) -> {
      pread(descriptor, offset, size)
      |> result.map_error(FileIssue)
      |> result.try(fn(bits) {
        transport.send(transport, socket, bytes_tree.from_bit_array(bits))
        |> result.map_error(SocketIssue)
      })
    }
  }
}

// -----------------------------------------------------------------------------
// FILE OPERATIONS
// -----------------------------------------------------------------------------

@external(erlang, "mist_ffi", "open_file")
pub fn open(path: String) -> Result(File, FileError)

@external(erlang, "mist_ffi", "close_file")
pub fn close(file: IoDevice) -> Result(Nil, FileError)

@external(erlang, "file", "sendfile")
fn send_file(
  descriptor descriptor: IoDevice,
  socket socket: Socket,
  offset offset: Int,
  bytes bytes: Int,
  options options: List(a),
) -> Result(Nil, glisten.SocketReason)

@external(erlang, "file", "pread")
fn pread(
  descriptor: IoDevice,
  location: Int,
  number: Int,
) -> Result(BitArray, FileError)
