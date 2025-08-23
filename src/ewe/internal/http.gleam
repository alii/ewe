import ewe/internal/decoder.{
  AbsPath, HttpBin, HttpEoh, HttpHeader, HttpRequest, HttphBin, More, Packet,
}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/option
import gleam/result.{replace_error, try}
import gleam/string
import gleam/uri
import glisten
import glisten/socket
import glisten/transport

pub type ParseError {
  InvalidMethod
  InvalidTarget
  InvalidVersion

  InvalidHeaders
  MissingHost

  InvalidBody

  // ???
  PacketLoss
}

pub type Connection {
  Connection(
    transport: transport.Transport,
    socket: socket.Socket,
    buffer: BitArray,
  )
}

pub fn transform_connection(connection: glisten.Connection(a)) -> Connection {
  Connection(
    transport: connection.transport,
    socket: connection.socket,
    buffer: <<>>,
  )
}

pub type Handler =
  fn(Request(Connection)) -> Response(bytes_tree.BytesTree)

// 1MB = 1M bytes
const max_reading_size = 1_000_000

pub fn read_from_socket(
  transport: transport.Transport,
  socket: socket.Socket,
  amount amount: Int,
  buffer buffer: BitArray,
  on_error on_error: ParseError,
) -> Result(BitArray, ParseError) {
  let read_size = int.min(amount, max_reading_size)

  use data <- try(
    transport.receive_timeout(transport, socket, read_size, 10_000)
    |> replace_error(on_error),
  )

  let amount = amount - read_size
  let buffer = <<buffer:bits, data:bits>>

  case amount > 0 {
    True -> read_from_socket(transport, socket, amount:, buffer:, on_error:)
    False -> Ok(buffer)
  }
}

pub type HttpVersion {
  Http10
  Http11
}

pub type ParsedRequest {
  ParsedRequest(request: Request(Connection), version: HttpVersion)
}

pub fn parse_request(
  connection: Connection,
  buffer: BitArray,
) -> Result(ParsedRequest, ParseError) {
  case decoder.decode_packet(HttpBin, buffer, []) {
    Ok(Packet(HttpRequest(atom_method, AbsPath(target), version), rest)) -> {
      // Request Line
      use method <- try(
        decoder.decode_method(atom_method)
        |> replace_error(InvalidMethod),
      )

      use uri <- try(
        bit_array.to_string(target)
        |> try(uri.parse)
        |> replace_error(InvalidTarget),
      )

      use version <- try(case version {
        #(1, 0) -> Ok(Http10)
        #(1, 1) -> Ok(Http11)
        _ -> Error(InvalidVersion)
      })

      // Headers
      use #(headers, rest) <- try(parse_headers(
        connection.transport,
        connection.socket,
        rest,
        dict.new(),
      ))

      // Forming the request
      let scheme = case connection.transport {
        transport.Tcp(..) -> http.Http
        transport.Ssl(..) -> http.Https
      }

      use #(host, port) <- try(
        dict.get(headers, "host")
        |> try(string.split_once(_, ":"))
        |> result.replace_error(MissingHost),
      )

      let port =
        int.parse(port)
        |> result.unwrap(case scheme {
          http.Http -> 80
          http.Https -> 443
        })

      Ok(ParsedRequest(
        request: Request(
          method:,
          headers: dict.to_list(headers),
          body: Connection(..connection, buffer: rest),
          scheme:,
          host:,
          port: option.Some(port),
          path: uri.path,
          query: uri.query,
        ),
        version:,
      ))
    }
    Ok(More(size)) -> {
      let read_size = option.unwrap(size, 0)

      use buffer <- try(read_from_socket(
        connection.transport,
        connection.socket,
        amount: read_size,
        buffer: connection.buffer,
        on_error: PacketLoss,
      ))

      parse_request(connection, buffer)
    }
    _ -> Error(PacketLoss)
  }
}

fn parse_headers(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  headers: Dict(String, String),
) {
  case decoder.decode_packet(HttphBin, buffer, []) {
    Ok(Packet(HttpEoh, rest)) -> Ok(#(headers, rest))
    Ok(Packet(HttpHeader(_idx, _atom_field, field, value), rest)) -> {
      use field <- try(
        bit_array.to_string(field)
        |> result.map(string.lowercase)
        |> replace_error(InvalidHeaders),
      )

      use value <- try(
        bit_array.to_string(value)
        |> result.map(string.trim)
        |> replace_error(InvalidHeaders),
      )

      dict.insert(headers, field, value)
      |> parse_headers(transport, socket, rest, _)
    }
    Ok(More(size)) -> {
      let read_size = option.unwrap(size, 0)

      use buffer <- try(read_from_socket(
        transport,
        socket,
        amount: read_size,
        buffer:,
        on_error: InvalidHeaders,
      ))

      parse_headers(transport, socket, buffer, headers)
    }
    _ -> Error(InvalidHeaders)
  }
}

pub fn read_body(
  req: Request(Connection),
) -> Result(Request(BitArray), ParseError) {
  let transfer_encoding =
    request.get_header(req, "transfer-encoding")
    |> result.map(string.lowercase)

  case transfer_encoding {
    Ok("chunked") -> {
      use body <- try(
        read_chunked_body(
          req.body.transport,
          req.body.socket,
          req.body.buffer,
          <<>>,
        ),
      )

      Ok(request.set_body(req, body))
    }
    _ -> {
      let content_length =
        request.get_header(req, "content-length")
        |> try(int.parse)
        |> result.unwrap(0)

      let left = content_length - bit_array.byte_size(req.body.buffer)

      case content_length, left {
        0, 0 -> Ok(<<>>)
        0, _l | _cl, 0 -> Ok(req.body.buffer)
        _cl, _l ->
          read_from_socket(
            req.body.transport,
            req.body.socket,
            amount: left,
            buffer: req.body.buffer,
            on_error: InvalidBody,
          )
      }
      |> result.map(request.set_body(req, _))
    }
  }
}

pub fn read_chunked_body(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  body: BitArray,
) -> Result(BitArray, ParseError) {
  case parse_body_chunk(buffer) {
    Ok(Done) -> Ok(body)
    Ok(Incomplete) -> {
      use buffer <- try(read_from_socket(
        transport,
        socket,
        amount: 0,
        buffer:,
        on_error: InvalidBody,
      ))

      read_chunked_body(transport, socket, buffer, body)
    }
    Ok(Chunk(chunk, rest)) -> {
      let body = <<body:bits, chunk:bits>>

      read_chunked_body(transport, socket, rest, body)
    }
    Error(error) -> Error(error)
  }
}

pub type BodyChunk {
  Done
  Incomplete
  Chunk(BitArray, rest: BitArray)
}

pub fn parse_body_chunk(buffer: BitArray) -> Result(BodyChunk, ParseError) {
  case split(buffer, <<"\r\n">>, []) {
    // TODO: trailers
    [<<"0">>, _] -> Ok(Done)
    [chunk_size, rest] -> {
      use size <- try(
        bit_array.to_string(chunk_size)
        |> try(int.base_parse(_, 16))
        |> replace_error(InvalidBody),
      )

      case split(rest, <<"\r\n">>, []) {
        [chunk, rest] -> {
          case bit_array.byte_size(chunk) == size {
            True -> Ok(Chunk(chunk, rest))
            False -> Error(InvalidBody)
          }
        }
        _ -> Ok(Incomplete)
      }
    }
    _ -> Ok(Incomplete)
  }
}

@external(erlang, "binary", "split")
fn split(
  subject: BitArray,
  pattern: BitArray,
  options: List(atom.Atom),
) -> List(BitArray)
