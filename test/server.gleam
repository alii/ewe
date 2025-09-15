import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import gleam/string

import ewe

pub fn hi() {
  ewe.new(fn(_req) {
    "hi"
    |> ewe.TextData
    |> response.set_body(response.new(200), _)
    |> response.set_header("content-type", "text/plain; charset=utf-8")
  })
}

pub fn echoer() {
  ewe.new(fn(req) {
    let content_type =
      request.get_header(req, "content-type")
      |> result.unwrap("text/plain")

    case ewe.read_body(req, 1024) {
      Ok(req) -> {
        ewe.BitsData(req.body)
        |> response.set_body(response.new(200), _)
        |> response.set_header("content-type", content_type)
      }
      Error(_) -> response.new(400) |> response.set_body(ewe.Empty)
    }
  })
}

pub fn start(builder: ewe.Builder) {
  let name = process.new_name("ewe_test_server")

  let _ =
    ewe.with_name(builder, name)
    |> ewe.listening_random()
    |> ewe.quiet()
    |> ewe.start()

  ewe.get_server_info(name)
}

pub type HttpResponse {
  HttpResponse(
    version: String,
    status_code: Int,
    reason_phrase: String,
    headers: dict.Dict(String, String),
    body: String,
  )
}

pub type ParseError {
  InvalidStatusLine
  InvalidHeaders
  MalformedResponse
}

pub fn parse_http_response(
  raw_response: BitArray,
) -> Result(HttpResponse, ParseError) {
  case bit_array.to_string(raw_response) {
    Ok(response_str) -> parse_response_string(response_str)
    Error(_) -> Error(MalformedResponse)
  }
}

fn parse_response_string(response: String) -> Result(HttpResponse, ParseError) {
  case string.split_once(response, "\r\n\r\n") {
    Ok(#(headers_part, body)) -> {
      let lines = string.split(headers_part, "\r\n")

      case lines {
        [status_line, ..header_lines] -> {
          use #(version, status_code, reason_phrase) <- result.try(
            parse_status_line(status_line),
          )

          use headers <- result.try(parse_headers(header_lines, dict.new()))

          Ok(HttpResponse(
            version: version,
            status_code: status_code,
            reason_phrase: reason_phrase,
            headers: headers,
            body: body,
          ))
        }
        _ -> Error(MalformedResponse)
      }
    }
    Error(_) -> {
      let lines = string.split(response, "\r\n")

      case lines {
        [status_line, ..header_lines] -> {
          use #(version, status_code, reason_phrase) <- result.try(
            parse_status_line(status_line),
          )

          use headers <- result.try(parse_headers(header_lines, dict.new()))

          Ok(HttpResponse(
            version: version,
            status_code: status_code,
            reason_phrase: reason_phrase,
            headers: headers,
            body: "",
          ))
        }
        _ -> Error(MalformedResponse)
      }
    }
  }
}

fn parse_status_line(
  status_line: String,
) -> Result(#(String, Int, String), ParseError) {
  case string.split(status_line, " ") {
    [version, status_code_str, ..reason_parts] -> {
      case int.parse(status_code_str) {
        Ok(status_code) -> {
          let reason_phrase = string.join(reason_parts, " ")
          Ok(#(version, status_code, reason_phrase))
        }
        Error(_) -> Error(InvalidStatusLine)
      }
    }
    _ -> Error(InvalidStatusLine)
  }
}

fn parse_headers(
  lines: List(String),
  headers: dict.Dict(String, String),
) -> Result(dict.Dict(String, String), ParseError) {
  case lines {
    [] -> Ok(headers)
    [header_line, ..rest] -> {
      case string.split_once(header_line, ": ") {
        Ok(#(name, value)) -> {
          let headers = dict.insert(headers, string.lowercase(name), value)
          parse_headers(rest, headers)
        }
        Error(_) -> {
          case string.split_once(header_line, ":") {
            Ok(#(name, value)) -> {
              let headers =
                dict.insert(headers, string.lowercase(name), string.trim(value))
              parse_headers(rest, headers)
            }
            Error(_) -> Error(InvalidHeaders)
          }
        }
      }
    }
  }
}
