// NOTE: ewww crime mess

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result.{try}
import gleam/string
import gleam/uri

pub type ParseError {
  Incomplete
  Invalid

  UnsupportedVersion

  HostMissing
  MultiLineHeaderUnsupported
}

pub type Stage {
  Begin
  Headers
  // TODO: chunked body
  Body(content_length: Int)
  BodyChunked(chunk_size: Option(Int))
  Done
}

pub type Method {
  Get
  Post
  Put
  Delete
  Patch
  Options
  Head
}

pub fn parse_method(method: BitArray) -> Result(Method, ParseError) {
  case method {
    <<"GET">> -> Ok(Get)
    <<"POST">> -> Ok(Post)
    <<"PUT">> -> Ok(Put)
    <<"DELETE">> -> Ok(Delete)
    <<"PATCH">> -> Ok(Patch)
    <<"OPTIONS">> -> Ok(Options)
    <<"HEAD">> -> Ok(Head)
    _ -> Error(Invalid)
  }
}

pub type HttpVersion {
  Http11
}

pub type ParsingState {
  ParsingState(parsed: Option(Request), stage: Stage)
}

pub fn new_state() -> ParsingState {
  ParsingState(parsed: None, stage: Begin)
}

pub type Request {
  Request(
    request_line: RequestLine,
    headers: Dict(String, String),
    body: BitArray,
  )
}

pub type Parsed(value) {
  Parsed(value, remaining: BitArray)
}

pub type Parsing(value) =
  Result(Parsed(value), ParseError)

pub fn parse_request(
  state: ParsingState,
  buffer: BitArray,
) -> Result(Request, #(ParsingState, BitArray, ParseError)) {
  case state.stage {
    Begin -> {
      let parsed = {
        use Parsed(request_line, remaining) <- try(parse_request_line(buffer))

        let parsed = Request(request_line:, headers: dict.new(), body: <<>>)
        let new_state = ParsingState(parsed: Some(parsed), stage: Headers)

        Ok(#(new_state, remaining))
      }

      case parsed {
        Ok(#(state, remaining)) -> parse_request(state, remaining)
        Error(error) -> Error(#(state, buffer, error))
      }
    }
    Headers -> {
      let parsed = {
        use Parsed(headers, remaining) <- try(parse_header(buffer, dict.new()))

        // TODO: Parse host maybe?
        use <- bool.guard(!dict.has_key(headers, "host"), Error(HostMissing))

        use content_length <- try(case dict.has_key(headers, "content-length") {
          False -> Ok(None)
          True -> {
            let assert Ok(content_length) = dict.get(headers, "content-length")

            use content_length <- try(
              int.parse(content_length) |> result.replace_error(Invalid),
            )

            Ok(Some(content_length))
          }
        })

        use chunked <- try(case dict.has_key(headers, "transfer-encoding") {
          False -> Ok(None)
          True -> {
            let assert Ok(chunked) = dict.get(headers, "transfer-encoding")
            Ok(Some(chunked == "chunked"))
          }
        })

        let parsed =
          option.map(state.parsed, fn(parsed) { Request(..parsed, headers:) })

        let stage = case chunked, content_length {
          Some(True), _ -> BodyChunked(None)
          _, Some(content_length) -> Body(content_length:)
          _, _ -> Done
        }

        let new_state = ParsingState(parsed:, stage:)
        Ok(#(new_state, remaining))
      }

      case parsed {
        Ok(#(state, remaining)) -> parse_request(state, remaining)
        Error(error) -> Error(#(state, buffer, error))
      }
    }
    Body(content_length) -> {
      let parsed = {
        case buffer {
          <<body:bytes-size(content_length)>> -> {
            let parsed =
              option.map(state.parsed, fn(parsed) { Request(..parsed, body:) })

            let new_state = ParsingState(parsed:, stage: Done)
            Ok(#(new_state, <<>>))
          }
          <<_:bytes-size(content_length), _>> -> Error(Invalid)
          _ -> Error(Incomplete)
        }
      }

      case parsed {
        Ok(#(state, remaining)) -> parse_request(state, remaining)
        Error(error) -> Error(#(state, buffer, error))
      }
    }
    BodyChunked(chunk_size) -> {
      let parsed = {
        parse_chunked_body(buffer, chunk_size)
      }
    }
    Done -> {
      let assert option.Some(parsed) = state.parsed
      Ok(parsed)
    }
  }
}

pub type RequestLine {
  RequestLine(method: Method, uri: uri.Uri, version: HttpVersion)
}

fn parse_request_line(buffer: BitArray) -> Parsing(RequestLine) {
  use #(request_line, remaining) <- try(case split(buffer, <<"\r\n">>, []) {
    [request_line, remaining] -> Ok(#(request_line, remaining))
    _ -> Error(Incomplete)
  })

  use #(method, target, version) <- try(
    case split(request_line, <<" ">>, [atom.create("global")]) {
      [method, target, version] -> Ok(#(method, target, version))
      _ -> Error(Invalid)
    },
  )

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

  RequestLine(method, target, version)
  |> Parsed(remaining)
  |> Ok
}

pub fn parse_header(
  buffer: BitArray,
  headers: Dict(String, String),
) -> Parsing(Dict(String, String)) {
  // TODO: handle not combinable headers

  case buffer {
    <<"\r\n", rest:bits>> -> Ok(Parsed(headers, rest))
    <<"\t", _rest:bits>> | <<" ", _rest:bits>> ->
      Error(MultiLineHeaderUnsupported)
    _ -> {
      use #(header, rest) <- try(case split(buffer, <<"\r\n">>, []) {
        [header, rest] -> Ok(#(header, rest))
        _ -> Error(Incomplete)
      })

      use #(name, value) <- try(case split(header, <<":">>, []) {
        [name, value] -> Ok(#(name, value))
        _ -> Error(Invalid)
      })

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
        dict.upsert(headers, name, fn(exists) {
          case exists {
            option.Some(acc) -> acc <> ", " <> value
            option.None -> value
          }
        })

      parse_header(rest, headers)
    }
  }
}

pub fn parse_chunked_body(buffer: BitArray, chunk_size: Option(Int)) {
  todo
}

@external(erlang, "binary", "split")
fn split(
  subject: BitArray,
  pattern: BitArray,
  options: List(atom.Atom),
) -> List(BitArray)
