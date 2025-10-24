// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import logging

import glisten

import ewe/internal/http1.{type Connection, type ResponseBody} as ewe_http

import ewe/internal/http1/handler as http1_handler

// -----------------------------------------------------------------------------
// PUBLIC TYPES
// -----------------------------------------------------------------------------

// Custom message that can be sent to or received from the Glisten actor
pub type Message {
  IdleTimeout
}

// State of the Glisten actor
pub type GlistenState {
  GlistenState(timer: Option(process.Timer), subject: process.Subject(Message))
}

pub type State {
  Http1(state: http1_handler.State, self: process.Subject(Message))
}

// -----------------------------------------------------------------------------
// INTERNAL TYPES
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// PUBLIC API
// -----------------------------------------------------------------------------

/// Initializes the Glisten actor's state and selector for custom messages
pub fn init(_) -> #(State, Option(process.Selector(Message))) {
  let subject = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subject)

  #(Http1(http1_handler.init(), self: subject), Some(selector))
}

/// Main handler loop that processes HTTP requests
pub fn loop(
  handler: fn(Request(Connection)) -> Response(ResponseBody),
  on_crash: Response(ResponseBody),
  factory_name: process.Name(
    factory.Message(fn() -> Result(actor.Started(Nil), actor.StartError), Nil),
  ),
  idle_timeout: Int,
) -> glisten.Loop(State, Message) {
  fn(
    state: State,
    msg: glisten.Message(Message),
    conn: glisten.Connection(Message),
  ) -> glisten.Next(State, glisten.Message(Message)) {
    let sender = conn.subject
    let conn = ewe_http.transform_connection(conn, factory_name)

    case state, msg {
      Http1(state, self), glisten.Packet(msg) -> {
        let result =
          http1_handler.handle_packet(
            state,
            msg,
            conn,
            sender,
            handler,
            on_crash,
            idle_timeout,
          )

        case result {
          http1_handler.Continue(new_state) ->
            glisten.continue(Http1(new_state, self))
          http1_handler.Http2CleartextUpgrade(_req, _settings) -> {
            logging.log(
              logging.Debug,
              "Received HTTP/2 cleartext upgrade request",
            )
            glisten.stop()
          }
          http1_handler.Http2Upgrade(_data) -> {
            logging.log(logging.Debug, "Received HTTP/2 upgrade request")
            glisten.stop()
          }
          http1_handler.Stop -> glisten.stop()
        }
      }
      _, _ -> glisten.stop()
    }
  }
}
