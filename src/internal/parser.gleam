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
  ParsingState(request: Request, stage: Stage)
}

pub fn new_state() -> ParsingState {
  ParsingState(request: new_request(), stage: RequestLine)
}

pub type Request {
  Request(
    method: Method,
    target: String,
    version: HttpVersion,
    headers: Dict(String, String),
    body: BitArray,
  )
}

pub fn new_request() -> Request {
  Request(
    method: Get,
    target: "/",
    version: Http11,
    headers: dict.new(),
    body: <<>>,
  )
}

pub type Parsed(value) =
  Result(#(value, BitArray), ParseError)

pub fn parse_request(
  state: ParsingState,
  buffer: BitArray,
) -> Result(Request, #(ParsingState, BitArray, ParseError)) {
  case state.stage {
    RequestLine -> {
      let parsed = {
        use #(#(method, target, version), remaining) <- try(parse_request_line(
          buffer,
        ))

        let request = Request(method, target, version, dict.new(), <<>>)
        let new_state = ParsingState(request, Headers)

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

        let request = Request(..state.request, headers:)
        let new_state = ParsingState(request, Body)

        Ok(#(new_state, remaining))
      }

      case parsed {
        Ok(#(state, remaining)) -> parse_request(state, remaining)
        Error(error) -> Error(#(state, buffer, error))
      }
    }
    Body -> {
      let new_state = ParsingState(state.request, Done)
      parse_request(new_state, <<>>)
    }
    Done -> Ok(state.request)
  }
}

fn parse_request_line(
  buffer: BitArray,
) -> Parsed(#(Method, String, HttpVersion)) {
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

  // TODO: parse target
  use target <- try(
    bit_array.to_string(target) |> result.replace_error(Invalid),
  )

  use version <- try(case version {
    <<"HTTP/1.1">> -> Ok(Http11)
    <<"HTTP/", _:bytes>> -> Error(UnsupportedVersion)
    _ -> Error(Invalid)
  })

  Ok(#(#(method, target, version), remaining))
}

fn parse_header(
  buffer: BitArray,
  headers: Dict(String, String),
) -> Parsed(Dict(String, String)) {
  case buffer {
    <<"\r\n", rest:bits>> -> Ok(#(headers, rest))
    _ -> {
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
