import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/http
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result.{try}
import gleam/string
import gleam/uri

pub type ParseError {
  Incomplete(parser: Parser)

  Invalid
  UnsupportedVersion
  HostMissing
  MultiLineHeaderUnsupported
}

pub type Stage {
  RequestLine
  Headers
  Body(Option(BodyType))
  Done
}

pub type BodyType {
  ContentLength(Int)
  Chunked(chunk_size: Option(Int))
  Empty
}

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
    body: Option(BitArray),
  )
}

pub fn new_parsed_request() -> ParsedRequest {
  ParsedRequest(
    method: None,
    uri: None,
    version: None,
    headers: None,
    body: None,
  )
}

pub type Parser {
  Parser(parsed: ParsedRequest, stage: Stage, buffer: BitArray)
}

pub fn new_parser() -> Parser {
  Parser(parsed: new_parsed_request(), stage: RequestLine, buffer: <<>>)
}

pub fn pretty_print_parsed(parsed: ParsedRequest) {
  io.println("\n================================================")
  io.println("Request:")
  io.println("Method: " <> { parsed.method |> string.inspect })
  io.println("URI: " <> { parsed.uri |> string.inspect })
  io.println("Version: " <> { parsed.version |> string.inspect })
  io.println("Headers:")
  dict.each(parsed.headers |> option.unwrap(dict.new()), fn(key, value) {
    io.println(
      "  " <> { key |> string.inspect } <> ": " <> { value |> string.inspect },
    )
  })
  io.println("Body:")
  io.println(
    "  "
    <> {
      parsed.body
      |> option.unwrap(<<>>)
      |> bit_array.to_string
      |> result.unwrap("")
    },
  )
}

pub fn parse_request(parser: Parser) -> Result(ParsedRequest, ParseError) {
  let #(stage_parsed, finished) = case parser.stage {
    RequestLine -> #(handle_request_line(parser), False)
    Headers -> #(handle_headers(parser), False)
    Body(None) -> #(track_body_type(parser), False)
    Body(Some(Empty)) -> #(Ok(Parser(..parser, stage: Done)), False)
    Body(Some(ContentLength(content_length))) -> #(
      handle_body(parser, content_length),
      False,
    )
    Body(Some(Chunked(chunk_size))) -> #(
      handle_chunked_body(parser, chunk_size),
      False,
    )
    Done -> #(Ok(parser), True)
  }

  case stage_parsed, finished {
    Ok(parser), False -> parse_request(parser)
    Ok(parser), True -> Ok(parser.parsed)
    Error(error), _ -> Error(error)
  }
}

fn handle_request_line(parser: Parser) -> Result(Parser, ParseError) {
  let request_parts = case split(parser.buffer, <<"\r\n">>, []) {
    [request_line, remaining] -> Ok(#(request_line, remaining))
    _ -> Error(Incomplete(parser))
  }
  use #(request_line, remaining) <- try(request_parts)

  let global = atom.create("global")
  let request_line_parts = case split(request_line, <<" ">>, [global]) {
    [method, target, version] -> Ok(#(method, target, version))
    _ -> Error(Invalid)
  }
  use #(method, target, version) <- try(request_line_parts)

  use method <- try(parse_method(method))

  use target <- result.try(
    bit_array.to_string(target)
    |> result.map(uri.parse)
    |> result.flatten()
    |> result.replace_error(Invalid),
  )

  use version <- try(case version {
    <<"HTTP/1.1">> -> Ok(Http11)
    <<"HTTP/", _:bytes>> -> Error(UnsupportedVersion)
    _ -> Error(Invalid)
  })

  let parsed =
    ParsedRequest(
      ..parser.parsed,
      method: Some(method),
      uri: Some(target),
      version: Some(version),
    )

  Ok(Parser(parsed:, stage: Headers, buffer: remaining))
}

fn handle_headers(parser: Parser) -> Result(Parser, ParseError) {
  case parser.buffer {
    <<"\r\n", remaining:bits>> ->
      Ok(Parser(..parser, stage: Body(None), buffer: remaining))
    <<"\t", _rest:bits>> | <<" ", _rest:bits>> ->
      Error(MultiLineHeaderUnsupported)
    _ -> {
      let header_parts = case split(parser.buffer, <<"\r\n">>, []) {
        [header, remaining] -> Ok(#(header, remaining))
        _ -> Error(Incomplete(parser))
      }
      use #(header, remaining) <- try(header_parts)

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

      use value <- try(
        bit_array.to_string(value)
        |> result.map(string.trim)
        |> result.replace_error(Invalid),
      )

      let headers =
        option.unwrap(parser.parsed.headers, dict.new())
        |> dict.upsert(name, fn(exists) {
          case exists {
            option.Some(acc) -> acc <> ", " <> value
            option.None -> value
          }
        })
      let parsed = ParsedRequest(..parser.parsed, headers: Some(headers))

      handle_headers(Parser(..parser, parsed:, buffer: remaining))
    }
  }
}

fn track_body_type(parser: Parser) -> Result(Parser, ParseError) {
  case parser.parsed.headers {
    None -> Ok(Parser(..parser, stage: Body(None)))
    Some(headers) -> {
      let content_length =
        dict.get(headers, "content-length")
        |> result.map(int.parse)
        |> result.flatten()
      let transfer_encoding = dict.get(headers, "transfer-encoding")

      case transfer_encoding, content_length {
        Ok("chunked"), _ ->
          Ok(Parser(..parser, stage: Body(Some(Chunked(None)))))
        _, Ok(content_length) ->
          Ok(Parser(..parser, stage: Body(Some(ContentLength(content_length)))))
        _, _ -> Ok(Parser(..parser, stage: Body(Some(Empty))))
      }
    }
  }
}

fn handle_body(
  parser: Parser,
  content_length: Int,
) -> Result(Parser, ParseError) {
  case parser.buffer {
    <<body:bytes-size(content_length)>> -> {
      let parsed = ParsedRequest(..parser.parsed, body: Some(body))
      Ok(Parser(..parser, parsed:, stage: Done))
    }
    <<_:bytes-size(content_length), _>> -> Error(Invalid)
    _ -> Error(Incomplete(parser))
  }
}

fn handle_chunked_body(
  parser: Parser,
  chunk_size: Option(Int),
) -> Result(Parser, ParseError) {
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
              stage: Body(Some(Chunked(Some(chunk_size)))),
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
        <<"\r\n", trailers:bits>> -> {
          let parser = Parser(..parser, buffer: trailers)
          handle_headers(parser)
        }
        _ -> Error(Invalid)
      }
    }
    Some(size) -> {
      case parser.buffer {
        <<chunk:bytes-size(size), "\r\n", remaining:bits>> -> {
          let body = option.unwrap(parser.parsed.body, <<>>)
          let parsed =
            ParsedRequest(
              ..parser.parsed,
              body: Some(<<body:bits, chunk:bits>>),
            )
          let parser =
            Parser(parsed:, stage: Body(Some(Chunked(None))), buffer: remaining)
          handle_chunked_body(parser, None)
        }
        <<_:bytes-size(size), _>> -> Error(Invalid)
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
