import gleam/dynamic
import gleam/erlang/atom
import gleam/http
import gleam/option

pub type PacketType {
  HttpBin
  HttphBin
}

pub type AbsPath {
  AbsPath(BitArray)
}

pub type Version =
  #(Int, Int)

pub type HttpPacket {
  HttpRequest(method: atom.Atom, path: AbsPath, version: Version)
  HttpHeader(
    idx: Int,
    field: atom.Atom,
    unmodified_field: BitArray,
    value: BitArray,
  )
  HttpEoh
}

pub type Packet {
  Packet(HttpPacket, rest: BitArray)
  More(length: option.Option(Int))
}

@external(erlang, "ewe_ffi", "decode_packet")
pub fn decode_packet(
  type_ type_: PacketType,
  packet packet: BitArray,
  options options: List(a),
) -> Result(Packet, dynamic.Dynamic)

pub fn decode_method(method: atom.Atom) -> Result(http.Method, Nil) {
  let get = atom.create("GET")
  let post = atom.create("POST")
  let head = atom.create("HEAD")
  let put = atom.create("PUT")
  let delete = atom.create("DELETE")
  let trace = atom.create("TRACE")
  let connect = atom.create("CONNECT")
  let options = atom.create("OPTIONS")
  let patch = atom.create("PATCH")

  case method {
    _ if method == get -> Ok(http.Get)
    _ if method == post -> Ok(http.Post)
    _ if method == head -> Ok(http.Head)
    _ if method == put -> Ok(http.Put)
    _ if method == delete -> Ok(http.Delete)
    _ if method == trace -> Ok(http.Trace)
    _ if method == connect -> Ok(http.Connect)
    _ if method == options -> Ok(http.Options)
    _ if method == patch -> Ok(http.Patch)
    _ -> Error(Nil)
  }
}
