// TODO: body streaming
// TODO: gzip?

// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option
import gleam/result.{replace_error, try}
import gleam/set
import gleam/string
import gleam/string_tree
import gleam/uri

import glisten
import glisten/socket
import glisten/transport

import gramps/websocket as ws

import ewe/internal/decoder.{
  AbsPath, HttpBin, HttpEoh, HttpHeader, HttpRequest, HttphBin, More, Packet,
}
import ewe/internal/encoder

// -----------------------------------------------------------------------------
// TYPES
// -----------------------------------------------------------------------------

// HTTP response body types
pub type ResponseBody {
  TextData(String)
  BytesData(bytes_tree.BytesTree)
  BitsData(BitArray)
  StringTreeData(string_tree.StringTree)

  WebsocketConnection(process.Selector(process.Down))

  Empty
}

// HTTP parsing error types
pub type ParseError {
  // request line
  InvalidMethod
  InvalidTarget
  InvalidVersion

  // headers
  InvalidHeaders
  MissingHost

  // body
  InvalidBody
  BodyTooLarge

  // anomalies
  MalformedRequest
  PacketDiscard
}

// HTTP connection
pub type Connection {
  Connection(
    transport: transport.Transport,
    socket: socket.Socket,
    buffer: BitArray,
    http_version: option.Option(HttpVersion),
  )
}

// HTTP version enumeration
pub type HttpVersion {
  Http10
  Http11
}

// WebSocket upgrade error types
pub type UpgradeWebsocketError {
  VersionNot11OrGreater
  MethodNotGet
  MissingConnectionHeader
  InvalidConnectionHeader
  MissingUpgradeHeader
  InvalidUpgradeHeader
  MissingWebsocketVersion
  MissingWebsocketKey
}

// Chunked body parsing result
type BodyChunk {
  Done(rest: BitArray)
  Incomplete
  Chunk(BitArray, rest: BitArray)
}

// -----------------------------------------------------------------------------
// CONSTANTS
// -----------------------------------------------------------------------------

// 1MB = 1M bytes | TODO: config?
const max_reading_size = 1_000_000

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Transforms a glisten connection to `Connection` type
pub fn transform_connection(connection: glisten.Connection(a)) -> Connection {
  Connection(
    transport: connection.transport,
    socket: connection.socket,
    buffer: <<>>,
    http_version: option.None,
  )
}

/// Parses an HTTP request from the given buffer
pub fn parse_request(
  connection: Connection,
  buffer: BitArray,
) -> Result(Request(Connection), ParseError) {
  let transport = connection.transport
  let socket = connection.socket

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
        transport,
        socket,
        rest,
        dict.new(),
      ))

      // Forming the request
      let scheme = case transport {
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

      Ok(Request(
        method:,
        headers: dict.to_list(headers),
        body: Connection(
          ..connection,
          buffer: rest,
          http_version: option.Some(version),
        ),
        scheme:,
        host:,
        port: option.Some(port),
        path: uri.path,
        query: uri.query,
      ))
    }
    Ok(More(size)) -> {
      let read_size = option.unwrap(size, 0)

      use buffer <- try(read_from_socket(
        transport,
        socket,
        amount: read_size,
        buffer: connection.buffer,
        on_error: MalformedRequest,
      ))

      parse_request(connection, buffer)
    }
    _ -> Error(PacketDiscard)
  }
}

/// Reads the HTTP request body
pub fn read_body(
  req: Request(Connection),
  size_limit: Int,
) -> Result(Request(BitArray), ParseError) {
  use _ <- try(handle_continue(req))

  let transport = req.body.transport
  let socket = req.body.socket

  let transfer_encoding =
    request.get_header(req, "transfer-encoding")
    |> result.map(string.lowercase)

  case transfer_encoding {
    Ok("chunked") -> {
      use #(body, rest) <- try(read_chunked_body(
        transport,
        socket,
        req.body.buffer,
        <<>>,
        size_limit,
        0,
      ))

      let req = request.set_body(req, body)

      case list.key_find(req.headers, "trailer") {
        Ok(trailer) -> {
          let set =
            trailer
            |> string.split(",")
            |> list.fold(set.new(), fn(set, field) {
              set.insert(set, string.trim(field) |> string.lowercase())
            })

          Ok(handle_trailers(req, set, rest))
        }
        Error(Nil) -> Ok(req)
      }
    }
    _ -> {
      let content_length =
        request.get_header(req, "content-length")
        |> try(int.parse)
        |> result.unwrap(0)

      use <- bool.guard(content_length > size_limit, Error(BodyTooLarge))

      let left = content_length - bit_array.byte_size(req.body.buffer)

      case content_length, left {
        0, 0 -> Ok(<<>>)
        0, _l | _cl, 0 -> Ok(req.body.buffer)
        _cl, _l ->
          read_from_socket(
            transport,
            socket,
            amount: left,
            buffer: req.body.buffer,
            on_error: InvalidBody,
          )
      }
      |> result.map(request.set_body(req, _))
    }
  }
}

/// Upgrades an HTTP connection to WebSocket
pub fn upgrade_websocket(
  req: Request(Connection),
  transport: transport.Transport,
  socket: socket.Socket,
) -> Result(#(List(String), Bool), UpgradeWebsocketError) {
  let assert option.Some(http_version) = req.body.http_version

  use <- bool.guard(http_version != Http11, Error(VersionNot11OrGreater))
  use <- bool.guard(req.method != http.Get, Error(MethodNotGet))

  use _ <- try(case request.get_header(req, "connection") {
    Ok("Upgrade") -> Ok(Nil)
    Ok(_) -> Error(InvalidConnectionHeader)
    Error(_) -> Error(MissingConnectionHeader)
  })

  use _ <- try(case request.get_header(req, "upgrade") {
    Ok("websocket") -> Ok(Nil)
    Ok(_) -> Error(InvalidUpgradeHeader)
    Error(_) -> Error(MissingUpgradeHeader)
  })

  use <- bool.guard(
    request.get_header(req, "sec-websocket-version") == Error(Nil),
    Error(MissingWebsocketVersion),
  )

  use key <- try(
    request.get_header(req, "sec-websocket-key")
    |> result.replace_error(MissingWebsocketKey),
  )

  let accept_key = ws.parse_websocket_key(key)

  let extensions =
    request.get_header(req, "sec-websocket-extensions")
    |> result.map(string.split(_, ";"))
    |> result.unwrap([])

  let permessage_deflate = ws.has_deflate(extensions)

  let resp =
    response.new(101)
    |> response.set_body(bytes_tree.new())
    |> response.set_header("connection", "upgrade")
    |> response.set_header("upgrade", "websocket")
    |> response.set_header("sec-websocket-accept", accept_key)
    |> response.set_header("sec-websocket-version", "13")

  let resp = case permessage_deflate {
    True ->
      response.set_header(
        resp,
        "sec-websocket-extensions",
        "permessage-deflate",
      )
    False -> resp
  }

  let _ =
    encoder.encode_response(resp)
    |> transport.send(transport, socket, _)

  Ok(#(extensions, permessage_deflate))
}

/// Appends default headers to HTTP responses
pub fn append_default_headers(
  resp: response.Response(bytes_tree.BytesTree),
  version: HttpVersion,
) -> response.Response(bytes_tree.BytesTree) {
  let body_size = bytes_tree.byte_size(resp.body)

  let resp = case response.get_header(resp, "content-length") {
    Ok(_) -> resp
    Error(Nil) ->
      response.set_header(resp, "content-length", int.to_string(body_size))
  }

  case version {
    Http10 -> response.set_header(resp, "connection", "close")
    Http11 -> {
      case response.get_header(resp, "connection") {
        Ok(_) -> resp
        Error(Nil) -> response.set_header(resp, "connection", "keep-alive")
      }
    }
  }
}

// -----------------------------------------------------------------------------
// SOCKET OPERATIONS
// -----------------------------------------------------------------------------

/// Reads data from socket with timeout and size limits
fn read_from_socket(
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

// -----------------------------------------------------------------------------
// HEADER PARSING
// -----------------------------------------------------------------------------

/// Parses HTTP headers from the buffer
fn parse_headers(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  headers: Dict(String, String),
) {
  case decoder.decode_packet(HttphBin, buffer, []) {
    Ok(Packet(HttpEoh, rest)) -> Ok(#(headers, rest))
    Ok(Packet(HttpHeader(idx, field, value), rest)) -> {
      use field <- try(case decoder.formatted_field_by_idx(idx) {
        Ok(field) -> Ok(field)
        Error(Nil) -> {
          bit_array.to_string(field)
          |> result.map(string.lowercase)
          |> replace_error(InvalidHeaders)
        }
      })

      use value <- try(
        bit_array.to_string(value)
        |> replace_error(InvalidHeaders),
      )

      insert_header(headers, field, value)
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

/// Inserts a header into the headers dictionary
fn insert_header(
  headers: Dict(String, String),
  field: String,
  value: String,
) -> Dict(String, String) {
  case field != "set-cookie" {
    True ->
      dict.upsert(headers, field, fn(target) {
        case target {
          option.Some(existing) -> existing <> ", " <> value
          option.None -> value
        }
      })
    False -> dict.insert(headers, available_cookie_key(headers, 0), value)
  }
}

/// Finds an available key for set-cookie headers
fn available_cookie_key(headers: Dict(String, String), idx: Int) -> String {
  let key = case idx {
    0 -> "set-cookie"
    n -> "set-cookie-" <> int.to_string(n)
  }

  case dict.has_key(headers, key) {
    True -> available_cookie_key(headers, idx + 1)
    False -> key
  }
}

// -----------------------------------------------------------------------------
// REQUEST HANDLING
// -----------------------------------------------------------------------------

/// Handles 100-continue expectations
fn handle_continue(req: Request(Connection)) -> Result(Nil, ParseError) {
  let expect =
    req.headers
    |> list.find(fn(tupple) {
      tupple.0 == "expect" && string.lowercase(tupple.1) == "100-continue"
    })

  case expect {
    Ok(_) -> {
      response.new(100)
      |> response.set_body(bytes_tree.new())
      |> encoder.encode_response()
      |> transport.send(req.body.transport, req.body.socket, _)
      |> result.replace_error(MalformedRequest)
    }
    Error(Nil) -> Ok(Nil)
  }
}

// -----------------------------------------------------------------------------
// CHUNKED BODY PARSING
// -----------------------------------------------------------------------------

/// Reads chunked transfer-encoded body
fn read_chunked_body(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  body: BitArray,
  size_limit: Int,
  total_size: Int,
) -> Result(#(BitArray, BitArray), ParseError) {
  use <- bool.guard(total_size > size_limit, Error(BodyTooLarge))

  case parse_body_chunk(buffer) {
    Ok(Done(rest)) -> Ok(#(body, rest))
    Ok(Incomplete) -> {
      use buffer <- try(read_from_socket(
        transport,
        socket,
        amount: 0,
        buffer:,
        on_error: InvalidBody,
      ))

      read_chunked_body(transport, socket, buffer, body, size_limit, total_size)
    }
    Ok(Chunk(chunk, rest)) -> {
      let body = <<body:bits, chunk:bits>>
      let total_size = total_size + bit_array.byte_size(chunk)

      read_chunked_body(transport, socket, rest, body, size_limit, total_size)
    }
    Error(error) -> Error(error)
  }
}

/// Parses a single chunk from the chunked body
fn parse_body_chunk(buffer: BitArray) -> Result(BodyChunk, ParseError) {
  case split(buffer, <<"\r\n">>, []) {
    [<<"0">>, rest] -> Ok(Done(rest))
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

// -----------------------------------------------------------------------------
// TRAILER HEADERS
// -----------------------------------------------------------------------------

/// Handles trailer headers in chunked responses
fn handle_trailers(
  req: Request(BitArray),
  set: set.Set(String),
  rest: BitArray,
) -> Request(BitArray) {
  case decoder.decode_packet(HttphBin, rest, []) {
    Ok(Packet(HttpEoh, _)) -> req
    Ok(Packet(HttpHeader(idx, field, value), rest)) -> {
      let field = case decoder.formatted_field_by_idx(idx) {
        Ok(field) -> Ok(field)
        Error(Nil) -> {
          bit_array.to_string(field)
          |> result.map(string.lowercase)
        }
      }

      case field {
        Ok(field) -> {
          case set.contains(set, field) && !is_forbidden_trailer(field) {
            True -> {
              case bit_array.to_string(value) {
                Ok(value) -> {
                  request.set_header(req, field, value)
                  |> handle_trailers(set, rest)
                }
                Error(Nil) -> handle_trailers(req, set, rest)
              }
            }
            False -> handle_trailers(req, set, rest)
          }
        }
        Error(Nil) -> handle_trailers(req, set, rest)
      }
    }
    _ -> req
  }
}

/// Checks if a header field is forbidden in trailers
fn is_forbidden_trailer(field: String) -> Bool {
  case string.lowercase(field) {
    "transfer-encoding"
    | "content-length"
    | "host"
    | "cache-control"
    | "expect"
    | "max-forwards"
    | "pragma"
    | "range"
    | "te" -> True
    _ -> False
  }
}

// -----------------------------------------------------------------------------
// EXTERNAL FFI
// -----------------------------------------------------------------------------

/// Splits binary data using external Erlang binary:split
@external(erlang, "binary", "split")
fn split(
  subject: BitArray,
  pattern: BitArray,
  options: List(atom.Atom),
) -> List(BitArray)
