// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result.{replace_error, try}
import gleam/set.{type Set}
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam/uri

import glisten
import glisten/socket.{type Socket}
import glisten/transport.{type Transport}

import gramps/websocket as ws

import ewe/internal/buffer.{type Buffer}
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
  BytesData(BytesTree)
  BitsData(BitArray)
  StringTreeData(StringTree)

  WebsocketConnection(Selector(process.Down))

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
    transport: Transport,
    socket: Socket,
    buffer: Buffer,
    http_version: Option(HttpVersion),
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

pub type Stream {
  Consumed(data: BitArray, next: fn(Int) -> Result(Stream, ParseError))
  Done
}

type Consumer =
  fn(Int) -> Result(Stream, ParseError)

// Chunked body parsing result
type BodyChunk {
  Incomplete
  Chunk(BitArray, size: Int, rest: Buffer)
  FinalChunk(rest: Buffer)
}

type ChunkedStreamState {
  ChunkedStreamState(data: Buffer, chunk: Buffer, done: Bool)
}

// -----------------------------------------------------------------------------
// CONSTANTS
// -----------------------------------------------------------------------------

// 1MB = 1M bytes
const max_reading_size = 1_000_000

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Transforms a glisten connection to `Connection` type
pub fn transform_connection(conn: glisten.Connection(a)) -> Connection {
  Connection(
    transport: conn.transport,
    socket: conn.socket,
    buffer: buffer.empty(),
    http_version: None,
  )
}

/// Parses an HTTP request from the given buffer
pub fn parse_request(
  conn: Connection,
  buffer: Buffer,
) -> Result(Request(Connection), ParseError) {
  let transport = conn.transport
  let socket = conn.socket

  case decoder.decode_packet(HttpBin, buffer) {
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
        buffer: buffer.new(rest),
        headers: dict.new(),
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
          ..conn,
          buffer: buffer.new(rest),
          http_version: Some(version),
        ),
        scheme:,
        host:,
        port: Some(port),
        path: uri.path,
        query: uri.query,
      ))
    }
    Ok(More(size)) -> {
      use new_buffer <- try(read_from_socket(
        transport,
        socket,
        buffer: buffer.sized(buffer, option.unwrap(size, 0)),
        on_error: MalformedRequest,
      ))

      parse_request(conn, new_buffer)
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
      use #(body, rest_buffer) <- try(read_chunked_body(
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

          Ok(handle_trailers(req, set, rest_buffer))
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

      let left = content_length - bit_array.byte_size(req.body.buffer.data)

      case content_length, left {
        0, 0 -> Ok(<<>>)
        0, _l | _cl, 0 -> Ok(req.body.buffer.data)
        _cl, _l ->
          read_from_socket(
            transport,
            socket,
            buffer: buffer.sized(req.body.buffer, left),
            on_error: InvalidBody,
          )
          |> result.map(fn(buffer) { buffer.data })
      }
      |> result.map(request.set_body(req, _))
    }
  }
}

/// Streams the HTTP request body
pub fn stream_body(req: Request(Connection)) {
  use _ <- result.try(
    handle_continue(req)
    |> result.replace_error(InvalidBody),
  )

  case request.get_header(req, "transfer-encoding") {
    Ok("chunked") -> {
      let state = ChunkedStreamState(buffer.empty(), req.body.buffer, False)
      Ok(do_stream_body_chunked(req, state))
    }
    _ -> {
      let content_length =
        request.get_header(req, "content-length")
        |> result.try(int.parse)
        |> result.unwrap(0)

      let remaining = content_length - bit_array.byte_size(req.body.buffer.data)
      let stream_buffer = buffer.sized(req.body.buffer, int.max(0, remaining))

      do_stream_body(req, stream_buffer)
      |> Ok
    }
  }
}

/// Upgrades an HTTP connection to WebSocket
pub fn upgrade_websocket(
  req: Request(Connection),
  transport: Transport,
  socket: Socket,
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
  resp: Response(BytesTree),
  req: Request(Connection),
  version: HttpVersion,
) -> Response(BytesTree) {
  let body_size = bytes_tree.byte_size(resp.body)
  let set_close = request.get_header(req, "connection") == Ok("close")

  let resp = case response.get_header(resp, "content-length") {
    Ok(_) -> resp
    Error(Nil) ->
      response.set_header(resp, "content-length", int.to_string(body_size))
  }

  case version, set_close {
    Http10, _ -> response.set_header(resp, "connection", "close")
    _, True -> response.set_header(resp, "connection", "close")
    Http11, False ->
      case response.get_header(resp, "connection") {
        Ok(_) -> resp
        Error(Nil) -> response.set_header(resp, "connection", "keep-alive")
      }
  }
}

// -----------------------------------------------------------------------------
// SOCKET OPERATIONS
// -----------------------------------------------------------------------------

/// Reads data from socket with timeout and size limits
fn read_from_socket(
  transport transport: Transport,
  socket socket: Socket,
  buffer buffer: Buffer,
  on_error on_error: ParseError,
) -> Result(Buffer, ParseError) {
  let read_size = int.min(buffer.remaining, max_reading_size)

  use data <- try(
    transport.receive_timeout(transport, socket, read_size, 10_000)
    |> replace_error(on_error),
  )

  let new_buffer = buffer.append_size(buffer, data, read_size)

  case new_buffer.remaining {
    0 -> Ok(new_buffer)
    _ -> read_from_socket(transport:, socket:, buffer: new_buffer, on_error:)
  }
}

// -----------------------------------------------------------------------------
// HEADERS
// -----------------------------------------------------------------------------

/// Parses HTTP headers from the buffer
fn parse_headers(
  transport transport: Transport,
  socket socket: Socket,
  buffer buffer: Buffer,
  headers headers: Dict(String, String),
) {
  case decoder.decode_packet(HttphBin, buffer) {
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

      let new_buffer = buffer.new(rest)

      insert_header(headers, field, value)
      |> parse_headers(transport:, socket:, buffer: new_buffer, headers: _)
    }
    Ok(More(size)) -> {
      let read_size = option.unwrap(size, 0)

      let sized_buffer = buffer.sized(buffer, read_size)

      use new_buffer <- try(read_from_socket(
        transport:,
        socket:,
        buffer: sized_buffer,
        on_error: InvalidHeaders,
      ))

      parse_headers(transport:, socket:, buffer: new_buffer, headers:)
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
pub fn handle_continue(req: Request(Connection)) -> Result(Nil, ParseError) {
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
// BODY
// -----------------------------------------------------------------------------

fn do_stream_body(req: Request(Connection), buffer: Buffer) -> Consumer {
  fn(size: Int) {
    let buffer_size = bit_array.byte_size(buffer.data)

    case buffer.remaining, buffer_size {
      // Request body is fully consumed
      0, 0 -> Ok(Done)

      // Request body is supposed to be fully consumed but there is more data in buffer
      0, _ -> {
        let #(data, rest) = buffer.split(buffer, size)
        Ok(Consumed(data, do_stream_body(req, buffer.new(rest))))
      }

      // Request body is not fully consumed and there is enough data in buffer to consume `size` bytes
      _, buffer_size if buffer_size >= size -> {
        let #(data, rest) = buffer.split(buffer, size)
        let new_buffer = buffer.new_sized(rest, buffer.remaining)
        Ok(Consumed(data, do_stream_body(req, new_buffer)))
      }

      // Request body is not fully consumed and there is not enough data in buffer to consume `size` bytes
      _, _ -> {
        use read_buffer <- try(read_from_socket(
          transport: req.body.transport,
          socket: req.body.socket,
          buffer: buffer.empty(),
          on_error: InvalidBody,
        ))

        let new_buffer =
          buffer.new_sized(
            <<buffer.data:bits, read_buffer.data:bits>>,
            int.max(0, buffer.remaining - bit_array.byte_size(read_buffer.data)),
          )

        let #(data, rest) = buffer.split(new_buffer, size)
        Ok(Consumed(data, do_stream_body(req, buffer.new(rest))))
      }
    }
  }
}

// -----------------------------------------------------------------------------
// CHUNKED BODY
// -----------------------------------------------------------------------------

/// Reads chunked transfer-encoded body
fn read_chunked_body(
  transport transport: Transport,
  socket socket: Socket,
  buffer buffer: Buffer,
  accumulated_body accumulated_body: BitArray,
  body_size_limit body_size_limit: Int,
  body_current_size body_current_size: Int,
) -> Result(#(BitArray, Buffer), ParseError) {
  use <- bool.guard(body_current_size > body_size_limit, Error(BodyTooLarge))

  case parse_body_chunk(buffer) {
    Ok(FinalChunk(rest)) -> Ok(#(accumulated_body, rest))
    Ok(Incomplete) -> {
      use new_buffer <- try(read_from_socket(
        transport:,
        socket:,
        buffer:,
        on_error: InvalidBody,
      ))

      read_chunked_body(
        transport:,
        socket:,
        buffer: new_buffer,
        accumulated_body:,
        body_size_limit:,
        body_current_size:,
      )
    }
    Ok(Chunk(chunk, size, rest)) ->
      read_chunked_body(
        transport:,
        socket:,
        buffer: rest,
        accumulated_body: <<accumulated_body:bits, chunk:bits>>,
        body_size_limit:,
        body_current_size: body_current_size + size,
      )
    Error(error) -> Error(error)
  }
}

/// Parses a single chunk from the chunked body
fn parse_body_chunk(buffer: Buffer) -> Result(BodyChunk, ParseError) {
  case split(buffer.data, <<"\r\n">>, []) {
    [<<"0">>, rest] -> Ok(FinalChunk(buffer.new(rest)))
    [chunk_size, rest] -> {
      use size <- try(
        bit_array.to_string(chunk_size)
        |> try(int.base_parse(_, 16))
        |> replace_error(InvalidBody),
      )

      case split(rest, <<"\r\n">>, []) {
        [chunk, rest] -> {
          case bit_array.byte_size(chunk) == size {
            True -> Ok(Chunk(chunk, size, buffer.new(rest)))
            False -> Error(InvalidBody)
          }
        }
        _ -> Ok(Incomplete)
      }
    }
    _ -> Ok(Incomplete)
  }
}

fn do_stream_body_chunked(
  req: Request(Connection),
  chunked_stream_state: ChunkedStreamState,
) -> Consumer {
  fn(size: Int) {
    let read_result =
      read_from_socket_until(
        transport: req.body.transport,
        socket: req.body.socket,
        state: chunked_stream_state,
        until: size,
      )

    case read_result {
      Ok(#(data, ChunkedStreamState(done: True, ..))) ->
        Ok(Consumed(data, fn(_) { Ok(Done) }))
      Ok(#(data, state)) ->
        Ok(Consumed(data, do_stream_body_chunked(req, state)))
      Error(_) -> Error(InvalidBody)
    }
  }
}

fn read_from_socket_until(
  transport transport: Transport,
  socket socket: Socket,
  state state: ChunkedStreamState,
  until until: Int,
) -> Result(#(BitArray, ChunkedStreamState), ParseError) {
  let size = bit_array.byte_size(state.data.data)

  case state.done, size {
    // Data buffer contains enough data to consume `until` bytes
    _, size if size >= until -> {
      let #(data, rest) = buffer.split(state.data, until)
      Ok(#(data, ChunkedStreamState(..state, data: buffer.new(rest))))
    }

    // Accomplished the reading
    True, _ -> Ok(#(state.data.data, state))

    // Data buffer does not contain enough data to consume `until` bytes
    False, _ -> {
      case parse_body_chunk(state.chunk) {
        Ok(FinalChunk(_)) ->
          read_from_socket_until(
            transport:,
            socket:,
            state: ChunkedStreamState(
              ..state,
              chunk: buffer.empty(),
              done: True,
            ),
            until:,
          )
        Ok(Incomplete) -> {
          use new_buffer <- try(read_from_socket(
            transport:,
            socket:,
            buffer: state.chunk,
            on_error: InvalidBody,
          ))

          read_from_socket_until(
            transport:,
            socket:,
            state: ChunkedStreamState(..state, chunk: new_buffer),
            until:,
          )
        }
        Ok(Chunk(chunk, size, rest)) -> {
          read_from_socket_until(
            transport:,
            socket:,
            state: ChunkedStreamState(
              ..state,
              data: buffer.append_size(state.data, chunk, size),
              chunk: rest,
            ),
            until:,
          )
        }
        Error(error) -> Error(error)
      }
    }
  }
}

// -----------------------------------------------------------------------------
// TRAILER HEADERS
// -----------------------------------------------------------------------------

/// Handles trailer headers in chunked responses
fn handle_trailers(
  req: Request(BitArray),
  set: Set(String),
  rest: Buffer,
) -> Request(BitArray) {
  case decoder.decode_packet(HttphBin, rest) {
    Ok(Packet(HttpEoh, _)) -> req
    Ok(Packet(HttpHeader(idx, field, value), header_rest)) -> {
      let field_name = case decoder.formatted_field_by_idx(idx) {
        Ok(field_name) -> Ok(field_name)
        Error(Nil) -> {
          bit_array.to_string(field)
          |> result.map(string.lowercase)
        }
      }

      case field_name {
        Ok(field_name) -> {
          case
            set.contains(set, field_name) && !is_forbidden_trailer(field_name)
          {
            True -> {
              case bit_array.to_string(value) {
                Ok(value) -> {
                  request.set_header(req, field_name, value)
                  |> handle_trailers(set, buffer.new(header_rest))
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
