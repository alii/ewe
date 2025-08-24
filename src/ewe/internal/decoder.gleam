import gleam/dynamic
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
  HttpRequest(method: BitArray, path: AbsPath, version: Version)
  HttpHeader(field: BitArray, value: BitArray)
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

pub fn decode_method(method: BitArray) -> Result(http.Method, Nil) {
  case method {
    <<"GET">> -> Ok(http.Get)
    <<"POST">> -> Ok(http.Post)
    <<"HEAD">> -> Ok(http.Head)
    <<"PUT">> -> Ok(http.Put)
    <<"DELETE">> -> Ok(http.Delete)
    <<"TRACE">> -> Ok(http.Trace)
    <<"CONNECT">> -> Ok(http.Connect)
    <<"OPTIONS">> -> Ok(http.Options)
    <<"PATCH">> -> Ok(http.Patch)
    _ -> Error(Nil)
  }
}
