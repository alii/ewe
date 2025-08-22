import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result.{try}
import gleam/set.{type Set}
import gleam/string
import gleam/uri

pub type ParseError {
  Incomplete(parser: Parser)

  Invalid
  TooLarge
  UnsupportedVersion
  HostMissing
  MultiLineHeaderUnsupported
}

pub type Stage {
  RequestLine
  Headers
  Body(BodyType)
  Trailers
  Done
}

pub type BodyType {
  ContentLength(Int)
  Chunked(chunk_size: Option(Int))
  Empty
}

// 8 KB
const max_request_line_size = 8192

// 8000 octets
const max_target_size = 8000

// 8 KB
const max_header_size = 8192

// 4 KB
const max_header_value_size = 4096

// 10 MB
const max_body_size = 10_485_760

const max_headers_amount = 100

pub fn parse_method(method: BitArray) -> Result(http.Method, ParseError) {
  case method {
    <<"GET">> -> Ok(http.Get)
    <<"POST">> -> Ok(http.Post)
    <<"PUT">> -> Ok(http.Put)
    <<"DELETE">> -> Ok(http.Delete)
    <<"PATCH">> -> Ok(http.Patch)
    <<"OPTIONS">> -> Ok(http.Options)
    <<"HEAD">> -> Ok(http.Head)
    _ -> Error(Invalid)
  }
}

pub type HttpVersion {
  Http11
}

pub type ParsedRequest {
  ParsedRequest(
    method: Option(http.Method),
    uri: Option(uri.Uri),
    version: Option(HttpVersion),
    headers: Option(Dict(String, String)),
    trailers: Option(Set(String)),
    body: Option(BitArray),
    body_size: Int,
  )
}

pub fn new_parsed_request() -> ParsedRequest {
  ParsedRequest(
    method: None,
    uri: None,
    version: None,
    headers: None,
    trailers: None,
    body: None,
    body_size: 0,
  )
}

pub type Parser {
  Parser(
    request: request.Request(BitArray),
    headers_: Dict(String, String),
    trailers_: Set(String),
    body_size_: Int,
    stage: Stage,
    buffer: BitArray,
  )
}

pub fn new_parser() -> Parser {
  Parser(
    request: request.new() |> request.set_body(<<>>),
    headers_: dict.new(),
    trailers_: set.new(),
    body_size_: 0,
    stage: RequestLine,
    buffer: <<>>,
  )
}

pub fn pretty_print_parsed(request: request.Request(BitArray)) {
  io.println("\n================================================")
  io.println("Request:")
  io.println("Method: " <> { request.method |> http.method_to_string() })
  io.println("Path: " <> { request.path })
  io.println("Query: " <> { request.query |> option.unwrap("-") })
  io.println("Headers:")
  request.headers
  |> list.each(fn(header) {
    io.println("  " <> { header.0 } <> ": " <> { header.1 })
  })
  io.println("Body:")
  io.println(
    "  "
    <> {
      request.body
      |> bit_array.to_string
      |> result.unwrap("-")
    },
  )
}

pub fn parse_request(
  parser: Parser,
) -> Result(request.Request(BitArray), ParseError) {
  let #(stage_parsed, finished) = case parser.stage {
    RequestLine -> #(handle_request_line(parser), False)
    Headers -> #(handle_headers(parser), False)
    Body(Empty) -> #(Ok(Parser(..parser, stage: Done)), False)
    Body(ContentLength(content_length)) -> #(
      handle_body(parser, content_length),
      False,
    )
    Body(Chunked(chunk_size)) -> #(
      handle_chunked_body(parser, chunk_size),
      False,
    )
    Trailers -> #(handle_headers(parser), False)
    Done -> #(Ok(parser), True)
  }

  case stage_parsed, finished {
    Ok(parser), False -> parse_request(parser)
    // Ok(parser), True -> Ok(parsed_to_http_request(parser.parsed))
    Ok(parser), True -> Ok(parser.request)
    Error(error), _ -> Error(error)
  }
}

fn handle_request_line(parser: Parser) -> Result(Parser, ParseError) {
  let request_parts = case split(parser.buffer, <<"\r\n">>, []) {
    [request_line, remaining] -> Ok(#(request_line, remaining))
    _ -> Error(Incomplete(parser))
  }
  use #(request_line, remaining) <- try(request_parts)

  use <- bool.guard(
    bit_array.byte_size(request_line) > max_request_line_size,
    Error(TooLarge),
  )

  let global = atom.create("global")
  let request_line_parts = case split(request_line, <<" ">>, [global]) {
    [method, target, version] -> Ok(#(method, target, version))
    _ -> Error(Invalid)
  }
  use #(method, target, version) <- try(request_line_parts)

  use <- bool.guard(
    bit_array.byte_size(target) > max_target_size,
    Error(TooLarge),
  )

  use method <- try(parse_method(method))

  use target <- result.try(
    bit_array.to_string(target)
    |> result.map(uri.parse)
    |> result.flatten()
    |> result.replace_error(Invalid),
  )

  use _version <- try(case version {
    <<"HTTP/1.1">> -> Ok(Http11)
    <<"HTTP/", _:bytes>> -> Error(UnsupportedVersion)
    _ -> Error(Invalid)
  })

  let request =
    request.Request(
      ..parser.request,
      scheme: http.Http,
      method: method,
      host: target.host |> option.unwrap("localhost"),
      port: target.port,
      path: target.path,
      query: target.query,
    )

  Ok(Parser(..parser, request:, stage: Headers, buffer: remaining))
}

fn handle_headers(parser: Parser) -> Result(Parser, ParseError) {
  use <- bool.guard(
    dict.size(parser.headers_) > max_headers_amount,
    Error(TooLarge),
  )

  case parser.buffer, parser.stage {
    <<"\r\n", remaining:bits>>, Headers -> {
      let content_length =
        dict.get(parser.headers_, "content-length")
        |> result.map(int.parse)
        |> result.flatten()

      let transfer_encoding = dict.get(parser.headers_, "transfer-encoding")

      let parser = case transfer_encoding, content_length {
        Ok("chunked"), _ ->
          Parser(..parser, stage: Body(Chunked(None)), buffer: remaining)
        _, Ok(content_length) ->
          Parser(
            ..parser,
            stage: Body(ContentLength(content_length)),
            buffer: remaining,
          )
        _, _ -> Parser(..parser, stage: Body(Empty), buffer: remaining)
      }

      Ok(parser)
    }
    <<"\r\n">>, Trailers -> {
      let request =
        request.Request(
          ..parser.request,
          headers: parser.headers_ |> dict.to_list(),
        )
      Ok(Parser(..parser, request:, stage: Done))
    }
    <<"\r\n", _rest:bits>>, Trailers -> Error(Invalid)
    <<"\t", _rest:bits>>, Headers -> Error(MultiLineHeaderUnsupported)
    <<" ", _rest:bits>>, Headers -> Error(MultiLineHeaderUnsupported)
    _, _ -> {
      case handle_header(parser) {
        Ok(parser) -> handle_headers(parser)
        Error(error) -> Error(error)
      }
    }
  }
}

fn handle_header(parser: Parser) -> Result(Parser, ParseError) {
  let header_parts = case split(parser.buffer, <<"\r\n">>, []) {
    [header, remaining] -> Ok(#(header, remaining))
    _ -> Error(Incomplete(parser))
  }
  use #(header, remaining) <- try(header_parts)

  use <- bool.guard(
    bit_array.byte_size(header) > max_header_size,
    Error(TooLarge),
  )

  let header_parts = case split(header, <<":">>, []) {
    [name, value] -> Ok(#(name, value))
    _ -> Error(Invalid)
  }
  use #(name, value) <- try(header_parts)

  use name <- try(
    bit_array.to_string(name)
    |> result.map(string.lowercase)
    |> result.replace_error(Invalid),
  )

  use <- bool.guard(string.contains(name, " "), Error(Invalid))

  let skip = case parser.stage {
    Trailers -> !set.contains(parser.trailers_, name)
    _ -> False
  }

  case skip {
    True -> {
      Ok(Parser(..parser, buffer: remaining))
    }
    False -> {
      use value <- try(
        bit_array.to_string(value)
        |> result.map(string.trim)
        |> result.replace_error(Invalid),
      )

      use <- bool.guard(
        string.byte_size(value) > max_header_value_size,
        Error(TooLarge),
      )

      let headers =
        dict.upsert(parser.headers_, name, fn(exists) {
          case exists {
            option.Some(acc) -> acc <> ", " <> value
            option.None -> value
          }
        })

      let trailers = case name {
        "trailer" -> {
          string.split(value, ",")
          |> list.fold(parser.trailers_, fn(acc, trailer) {
            set.insert(acc, string.trim(trailer) |> string.lowercase())
          })
        }
        _ -> parser.trailers_
      }

      let parser =
        Parser(
          ..parser,
          headers_: headers,
          trailers_: trailers,
          buffer: remaining,
        )

      Ok(parser)
    }
  }
}

fn handle_body(
  parser: Parser,
  content_length: Int,
) -> Result(Parser, ParseError) {
  use <- bool.guard(content_length > max_body_size, Error(TooLarge))

  case parser.buffer {
    <<body:bytes-size(content_length)>> -> {
      let request = request.Request(..parser.request, body:)
      Ok(Parser(..parser, request:, stage: Done))
    }
    <<_:bytes-size(content_length), _>> -> Error(Invalid)
    _ -> Error(Incomplete(parser))
  }
}

fn handle_chunked_body(
  parser: Parser,
  chunk_size: Option(Int),
) -> Result(Parser, ParseError) {
  use <- bool.guard(parser.body_size_ > max_body_size, Error(TooLarge))

  case chunk_size {
    None -> {
      case split(parser.buffer, <<"\r\n">>, []) {
        [possible_size, remaining] -> {
          use chunk_size <- try(
            bit_array.to_string(possible_size)
            |> result.map(int.base_parse(_, 16))
            |> result.flatten()
            |> result.replace_error(Invalid),
          )

          let parser =
            Parser(
              ..parser,
              stage: Body(Chunked(Some(chunk_size))),
              buffer: remaining,
            )

          handle_chunked_body(parser, Some(chunk_size))
        }
        _ -> Error(Incomplete(parser))
      }
    }
    Some(0) -> {
      case parser.buffer {
        <<"\r\n">> -> Ok(Parser(..parser, stage: Done))
        trailers -> {
          Ok(Parser(..parser, stage: Trailers, buffer: trailers))
        }
      }
    }
    Some(size) -> {
      use <- bool.guard(
        size > max_body_size / 10 || parser.body_size_ + size > max_body_size,
        Error(TooLarge),
      )

      case parser.buffer {
        <<chunk:bytes-size(size), "\r\n", remaining:bits>> -> {
          let request =
            request.Request(..parser.request, body: <<
              parser.request.body:bits,
              chunk:bits,
            >>)

          let parser =
            Parser(
              ..parser,
              request:,
              body_size_: parser.body_size_ + size,
              stage: Body(Chunked(None)),
              buffer: remaining,
            )

          handle_chunked_body(parser, None)
        }
        // <<_:bytes-size(size), _>> -> Error(Invalid)
        _ -> Error(Incomplete(parser))
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
