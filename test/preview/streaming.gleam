import gleam/string

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/result
import logging

import ewe.{type Request, type Response}

pub type Message {
  Chunk(BitArray)
  Done
  BodyError(ewe.BodyError)
}

fn stream_resource(
  consumer: ewe.Consumer,
  subject: Subject(Message),
  chunk_size: Int,
) -> Nil {
  process.sleep(int.random(250))
  case consumer(chunk_size) {
    Ok(ewe.Consumed(data, next)) -> {
      logging.log(logging.Info, {
        "Consumed "
        <> int.to_string(bit_array.byte_size(data))
        <> " bytes: "
        <> string.inspect(data)
      })

      process.send(subject, Chunk(data))
      stream_resource(next, subject, chunk_size)
    }
    Ok(ewe.Done) -> {
      process.send(subject, Done)
    }
    Error(body_error) -> {
      process.send(subject, BodyError(body_error))
    }
  }
}

fn handle_stream(req: Request, chunk_size: Int) -> Response {
  let content_type =
    request.get_header(req, "content-type")
    |> result.unwrap("application/octet-stream")

  case ewe.stream_body(req) {
    Ok(consumer) -> {
      ewe.chunked_body(
        req,
        response.new(200) |> response.set_header("content-type", content_type),
        on_init: fn(subject) {
          process.spawn(fn() { stream_resource(consumer, subject, chunk_size) })

          Nil
        },
        handler: fn(chunked_body, state, message) {
          case message {
            Chunk(data) ->
              case ewe.send_chunk(chunked_body, data) {
                Ok(Nil) -> ewe.chunked_continue(state)
                Error(_) -> ewe.chunked_stop_abnormal("Failed to send chunk")
              }
            Done -> ewe.chunked_stop()
            BodyError(body_error) ->
              ewe.chunked_stop_abnormal(string.inspect(body_error))
          }
        },
        on_close: fn(_conn, _state) {
          logging.log(logging.Info, "Stream closed")
        },
      )
    }
    Error(_) ->
      response.new(400)
      |> response.set_header("content-type", "text/plain; charset=utf-8")
      |> response.set_body(ewe.TextData("Invalid request"))
  }
}

fn handler(req: Request) -> Response {
  case request.path_segments(req) {
    ["stream", chunk_size] ->
      int.parse(chunk_size)
      |> result.unwrap(16)
      |> handle_stream(req, _)
    _ ->
      response.new(404)
      |> response.set_body(ewe.Empty)
  }
}

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  let assert Ok(_) =
    ewe.new(handler)
    |> ewe.bind_all()
    |> ewe.listening(port: 8080)
    |> ewe.start()

  process.sleep_forever()
}
