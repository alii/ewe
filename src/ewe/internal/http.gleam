import ewe/internal/decoder.{
  AbsPath, HttpBin, HttpEoh, HttpHeader, HttpRequest, HttphBin, More, Packet,
}
import ewe/internal/encoder
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
import gleam/option
import gleam/result.{replace_error, try}
import gleam/string
import gleam/string_tree
import gleam/uri
import glisten
import glisten/socket
import glisten/transport
import gramps/websocket

pub type ResponseBody {
  TextData(String)
  BytesData(bytes_tree.BytesTree)
  BitsData(BitArray)
  StringTreeData(string_tree.StringTree)

  WebsocketConnection(process.Selector(process.Down))

  Empty
}

pub type ParseError {
  InvalidMethod
  InvalidTarget
  InvalidVersion

  InvalidHeaders
  MissingHost

  InvalidBody
  BodyTooLarge

  // ???
  PacketLoss
}

pub type Connection {
  Connection(
    transport: transport.Transport,
    socket: socket.Socket,
    buffer: BitArray,
    http_version: option.Option(HttpVersion),
  )
}

pub fn transform_connection(connection: glisten.Connection(a)) -> Connection {
  Connection(
    transport: connection.transport,
    socket: connection.socket,
    buffer: <<>>,
    http_version: option.None,
  )
}

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
    Ok(Packet(HttpHeader(field, value), rest)) -> {
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
  size_limit: Int,
) -> Result(Request(BitArray), ParseError) {
  let transport = req.body.transport
  let socket = req.body.socket

  let transfer_encoding =
    request.get_header(req, "transfer-encoding")
    |> result.map(string.lowercase)

  case transfer_encoding {
    Ok("chunked") -> {
      use body <- try(read_chunked_body(
        transport,
        socket,
        req.body.buffer,
        <<>>,
        size_limit,
        0,
      ))

      Ok(request.set_body(req, body))
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

fn read_chunked_body(
  transport: transport.Transport,
  socket: socket.Socket,
  buffer: BitArray,
  body: BitArray,
  size_limit: Int,
  total_size: Int,
) -> Result(BitArray, ParseError) {
  use <- bool.guard(total_size > size_limit, Error(BodyTooLarge))

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

pub type BodyChunk {
  Done
  Incomplete
  Chunk(BitArray, rest: BitArray)
}

fn parse_body_chunk(buffer: BitArray) -> Result(BodyChunk, ParseError) {
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

pub fn upgrade_websocket(
  req: Request(Connection),
  transport: transport.Transport,
  socket: socket.Socket,
) -> Result(Nil, UpgradeWebsocketError) {
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

  let accept_key = websocket.parse_websocket_key(key)

  // TODO: figure out what to do with extensions
  let _extensions =
    request.get_header(req, "sec-websocket-extensions")
    |> result.map(string.split(_, ";"))
    |> result.unwrap([])

  let _ =
    response.new(101)
    |> response.set_body(bytes_tree.new())
    |> response.set_header("connection", "upgrade")
    |> response.set_header("upgrade", "websocket")
    |> response.set_header("sec-websocket-accept", accept_key)
    |> response.set_header("sec-websocket-version", "13")
    |> encoder.encode_response()
    |> transport.send(transport, socket, _)

  Ok(Nil)
}

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

@external(erlang, "binary", "split")
fn split(
  subject: BitArray,
  pattern: BitArray,
  options: List(atom.Atom),
) -> List(BitArray)
