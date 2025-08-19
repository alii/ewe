// NOTE: ewww crime mess

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/int
import gleam/option
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
  Body(content_length: Int)
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
  ParsingState(parsed: option.Option(Parsed), stage: Stage)
}

pub fn new_state() -> ParsingState {
  ParsingState(parsed: option.None, stage: Begin)
}

pub type Parsed {
  Parsed(
    request_line: RequestLine,
    headers: Dict(String, String),
    body: BitArray,
  )
}

pub type Parsing(value) =
  Result(#(value, BitArray), ParseError)

pub fn parse_request(
  state: ParsingState,
  buffer: BitArray,
) -> Result(Parsed, #(ParsingState, BitArray, ParseError)) {
  case state.stage {
    Begin -> {
      let parsed = {
        use #(request_line, remaining) <- try(parse_request_line(buffer))

        let parsed = Parsed(request_line:, headers: dict.new(), body: <<>>)
        let new_state =
          ParsingState(parsed: option.Some(parsed), stage: Headers)

        Ok(#(new_state, remaining))
      }

      case parsed {
        Ok(#(state, remaining)) -> parse_request(state, remaining)
        Error(error) -> Error(#(state, buffer, error))
      }
    }
    Headers -> {
      let parsed = {
        use #(headers, remaining) <- try(parse_header(buffer, dict.new()))

        // TODO: Parse host maybe?
        use <- bool.guard(!dict.has_key(headers, "host"), Error(HostMissing))

        use content_length <- try(case dict.has_key(headers, "content-length") {
          False -> Ok(option.None)
          True -> {
            let assert Ok(content_length) = dict.get(headers, "content-length")

            use content_length <- try(
              int.parse(content_length) |> result.replace_error(Invalid),
            )

            Ok(option.Some(content_length))
          }
        })

        let parsed =
          option.map(state.parsed, fn(parsed) { Parsed(..parsed, headers:) })

        let stage = case content_length {
          option.None -> Done
          option.Some(content_length) -> Body(content_length:)
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
          <<body:bytes-size(content_length)>>
          | <<body:bytes-size(content_length), _rest:bits>> -> {
            let parsed =
              option.map(state.parsed, fn(parsed) { Parsed(..parsed, body:) })

            let new_state = ParsingState(parsed:, stage: Done)
            Ok(#(new_state, <<>>))
          }
          _ -> Error(Incomplete)
        }
      }

      case parsed {
        Ok(#(state, remaining)) -> parse_request(state, remaining)
        Error(error) -> Error(#(state, buffer, error))
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

  let parsed = RequestLine(method, target, version)

  Ok(#(parsed, remaining))
}

pub fn parse_header(
  buffer: BitArray,
  headers: Dict(String, String),
) -> Parsing(Dict(String, String)) {
  // TODO: handle not combinable headers

  case buffer {
    <<"\r\n", rest:bits>> -> Ok(#(headers, rest))
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

@external(erlang, "binary", "split")
fn split(
  subject: BitArray,
  pattern: BitArray,
  options: List(atom.Atom),
) -> List(BitArray)
