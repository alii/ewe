import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/result.{try}
import gleam/string

pub type ParseError {
  Incomplete
  Invalid
  UnsupportedVersion
}

pub type Stage {
  RequestLine
  Headers
  Body
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

pub fn parse_method(method: String) -> Result(Method, ParseError) {
  case method {
    "GET" -> Ok(Get)
    "POST" -> Ok(Post)
    "PUT" -> Ok(Put)
    "DELETE" -> Ok(Delete)
    "PATCH" -> Ok(Patch)
    "OPTIONS" -> Ok(Options)
    "HEAD" -> Ok(Head)
    _ -> Error(Invalid)
  }
}

pub type ParsingState {
  ParsingState(request: Request, stage: Stage, buffer: BitArray)
}

pub type HttpVersion {
  Http11
}

pub type Request {
  Request(method: Method, target: String, version: HttpVersion)
}

pub fn new_request() -> Request {
  Request(method: Get, target: "/", version: Http11)
}

pub fn parse_request(
  state: ParsingState,
) -> #(ParsingState, Result(Nil, ParseError)) {
  case state.stage {
    RequestLine -> {
      let parsed = {
        use #(request_line, rest) <- try(
          case split(state.buffer, <<"\r\n">>, []) {
            [request_line, rest] -> Ok(#(request_line, rest))
            _ -> Error(Incomplete)
          },
        )

        use #(method, target, version) <- try(parse_request_line(request_line))

        let request = Request(method, target, version)

        let new_state = ParsingState(request, Headers, rest)

        Ok(new_state)
      }

      case parsed {
        Ok(new_state) -> parse_request(new_state)
        Error(error) -> #(state, Error(error))
      }
    }
    Headers -> {
      echo "parsing headers next!"
      let headers = parse_header(state.buffer, dict.new())

      echo headers as "headers"

      #(state, Ok(Nil))
    }
    _ -> todo
  }
}

fn parse_request_line(buffer: BitArray) {
  use #(method, rest) <- try(case split(buffer, <<" ">>, []) {
    [method, rest] -> Ok(#(method, rest))
    _ -> Error(Incomplete)
  })

  use method <- try(
    bit_array.to_string(method) |> result.replace_error(Invalid),
  )

  use method <- try(parse_method(method) |> result.replace_error(Invalid))

  use #(target, version) <- try(case split(rest, <<" ">>, []) {
    [target, rest] -> Ok(#(target, rest))
    _ -> Error(Incomplete)
  })

  use target <- try(
    bit_array.to_string(target) |> result.replace_error(Invalid),
  )

  use _ <- try(case split(version, <<" ">>, []) {
    [_] -> Ok(Nil)
    _ -> Error(Invalid)
  })

  use version <- try(case version {
    <<"HTTP/1.1">> -> Ok(Http11)
    _ -> Error(UnsupportedVersion)
  })

  Ok(#(method, target, version))
}

fn parse_header(buffer: BitArray, headers: Dict(String, String)) {
  case bit_array.starts_with(buffer, <<"\r\n">>) {
    True -> Ok(headers)
    False -> {
      use #(header, rest) <- try(case split(buffer, <<"\r\n">>, []) {
        [header, rest] -> Ok(#(header, rest))
        _ -> Error(Incomplete)
      })

      use #(name, value) <- try(case split(header, <<": ">>, []) {
        [name, value] -> Ok(#(name, value))
        _ -> Error(Invalid)
      })

      use name <- try(
        bit_array.to_string(name) |> result.replace_error(Invalid),
      )

      use <- bool.guard(string.contains(name, " "), Error(Invalid))

      use value <- try(
        bit_array.to_string(value) |> result.replace_error(Invalid),
      )

      let headers = dict.insert(headers, name, string.trim(value))

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
