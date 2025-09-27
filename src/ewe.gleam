//// <style>
////   .content > h4,
////   .content > ul {
////     display: none;
////   }
//// </style>
//// <script>
//// // https://gitlab.com/arkandos/smol/-/blob/main/src/smol.gleam?ref_type=heads
//// (callback => document.readyState !== 'loading' ? callback() : document.addEventListener('DOMContentLoaded', callback, { once: true }))(() => {
////   const list = document.querySelector('.sidebar > ul:last-of-type')
////   const sortedLists = document.createDocumentFragment()
////   const sortedMembers = document.createDocumentFragment()
////
////   for (const header of document.querySelectorAll('main > h4')) {
////     sortedLists.append((() => {
////       const node = document.createElement('h3')
////       node.append(header.textContent)
////       return node
////     })())
////     sortedMembers.append((() => {
////       const node = document.createElement('h2')
////       node.append(header.textContent)
////       return node
////     })())
////
////     const sortedList = document.createElement('ul')
////     sortedLists.append(sortedList)
////
////     for (const anchor of header.nextElementSibling.querySelectorAll('a')) {
////       const href = anchor.getAttribute('href')
////       const member = document.querySelector(`.member:has(h2 > a[href="${href}"])`)
////       const sidebar = list.querySelector(`li:has(a[href="${href}"])`)
////       sortedList.append(sidebar)
////       sortedMembers.append(member)
////     }
////   }
////
////   document.querySelector('.sidebar').insertBefore(sortedLists, list)
////   document.querySelector('.module-members:has(#module-values)').insertBefore(sortedMembers, document.querySelector('#module-values').nextSibling)
//// })
//// </script>
//// #### IP Address
//// - [ip_address_to_string](#ip_address_to_string)
//// #### Information
//// - [get_client_info](#get_client_info)
//// - [get_server_info](#get_server_info)
//// #### Builder
//// - [new](#new)
//// - [bind](#bind)
//// - [bind_all](#bind_all)
//// - [listening](#listening)
//// - [listening_random](#listening_random)
//// - [enable_ipv6](#enable_ipv6)
//// - [enable_tls](#enable_tls)
//// - [with_name](#with_name)
//// - [quiet](#quiet)
//// - [idle_timeout](#idle_timeout)
//// - [on_start](#on_start)
//// - [on_crash](#on_crash)
//// #### Server
//// - [start](#start)
//// - [supervised](#supervised)
//// #### Request
//// - [read_body](#read_body)
//// - [stream_body](#stream_body)
//// #### Response
//// - [file](#file)
//// #### Websocket
//// - [upgrade_websocket](#upgrade_websocket)
//// - [send_binary_frame](#send_binary_frame)
//// - [send_text_frame](#send_text_frame)
//// - [websocket_continue](#websocket_continue)
//// - [websocket_continue_with_selector](#websocket_continue_with_selector)
//// - [websocket_stop](#websocket_stop)
//// - [websocket_stop_abnormal](#websocket_stop_abnormal)
//// #### Server-Sent Events
//// - [sse](#sse)
//// - [event](#event)
//// - [event_name](#event_name)
//// - [event_id](#event_id)
//// - [event_retry](#event_retry)
//// - [send_event](#send_event)
//// - [sse_continue](#sse_continue)
//// - [sse_stop](#sse_stop)
//// - [sse_stop_abnormal](#sse_stop_abnormal)

// -----------------------------------------------------------------------------
// IMPORTS
// -----------------------------------------------------------------------------

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http
import gleam/http/request.{type Request as HttpRequest}
import gleam/http/response.{type Response as HttpResponse}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string_tree.{type StringTree}
import gleam/yielder
import logging

import glisten
import glisten/internal/listener
import glisten/socket/options as glisten_options
import glisten/transport

// TODO: replace this once gramps changes are published
import ewe/internal/gramps/websocket as ws

import ewe/internal/file
import ewe/internal/handler
import ewe/internal/http as ewe_http
import ewe/internal/sse as ewe_sse
import ewe/internal/websocket as ewe_ws

// -----------------------------------------------------------------------------
// CONNECTION
// -----------------------------------------------------------------------------

/// Represents a default body stored inside a `Request` type. Contains
/// important information for retrieving the original request body or client's
/// information. Can be converted to a `BitArray` using `ewe.read_body`.
///
pub type Connection =
  ewe_http.Connection

// -----------------------------------------------------------------------------
// IP ADDRESS
// -----------------------------------------------------------------------------

/// Represents an IP address of a client/server.
///
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Converts an `IpAddress` to a `String`.
///
pub fn ip_address_to_string(address address: IpAddress) -> String {
  ewe_to_glisten_ip(address)
  |> glisten.ip_address_to_string()
}

fn glisten_to_ewe_ip(ip: glisten.IpAddress) -> IpAddress {
  case ip {
    glisten.IpV4(n1, n2, n3, n4) -> IpV4(n1, n2, n3, n4)
    glisten.IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

fn glisten_options_to_ewe_ip(ip: glisten_options.IpAddress) -> IpAddress {
  case ip {
    glisten_options.IpV4(n1, n2, n3, n4) -> IpV4(n1, n2, n3, n4)
    glisten_options.IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

fn ewe_to_glisten_ip(ip: IpAddress) -> glisten.IpAddress {
  case ip {
    IpV4(n1, n2, n3, n4) -> glisten.IpV4(n1, n2, n3, n4)
    IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      glisten.IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

// -----------------------------------------------------------------------------
// INFORMATION
// -----------------------------------------------------------------------------

/// Represents client/server information. Can be retrieved using
/// `ewe.get_client_info`/`ewe.get_server_info`.
///
pub type SocketAddress {
  SocketAddress(ip: IpAddress, port: Int)
}

/// Attempts to get the client's socket address using request's
/// connection.
///
pub fn get_client_info(
  connection connection: Connection,
) -> Result(SocketAddress, Nil) {
  transport.peername(connection.transport, connection.socket)
  |> result.map(fn(server_info) {
    SocketAddress(glisten_options_to_ewe_ip(server_info.0), server_info.1)
  })
}

/// Retrieves server's socket address. Requires the same name as the one used in
/// `ewe.with_name` and server to be started.
///
pub fn get_server_info(
  listener_name name: process.Name(listener.Message),
) -> SocketAddress {
  let server_info = glisten.get_server_info(name, 10_000)
  let ip_address = glisten_to_ewe_ip(server_info.ip_address)

  SocketAddress(ip: ip_address, port: server_info.port)
}

// -----------------------------------------------------------------------------
// RESPONSE
// -----------------------------------------------------------------------------

/// Represents possible response body options.
///
/// Types for direct usage:
/// - Regular data: `TextData`, `BytesData`, `BitsData`, `StringTreeData`,
///   `Empty`
/// - Chunked data: `ChunkedData`
///
/// Types that should not be used directly:
/// - `File`: see `ewe.file` to construct it.
/// - `WebsocketConnection`: used in `ewe.upgrade_websocket` for correct
/// WebSocket connection handling.
/// - `SSEConnection`: used in `ewe.sse` for correct
/// Server-Sent Events connection handling.
///
pub type ResponseBody {
  /// Allows to set response body from a string.
  ///
  TextData(String)
  /// Allows to set response body from bytes.
  ///
  BytesData(BytesTree)
  /// Allows to set response body from bits.
  ///
  BitsData(BitArray)
  /// Allows to set response body from a string tree.
  ///
  StringTreeData(StringTree)
  /// Allows to set empty response body.
  ///
  Empty

  /// Allows to send response body in chunks with `chunked` transfer encoding.
  ///
  ChunkedData(yielder.Yielder(BitArray))

  /// Allows to set response body from a file more efficiently rather than
  /// sending contents in regular data types.
  ///
  File(descriptor: file.IoDevice, offset: Int, size: Int)

  /// Allows upgrading request to a WebSocket connection.
  ///
  Websocket(MonitorSelector)
  /// Allows upgrading request to a Server-Sent Events connection.
  ///
  SSE(MonitorSelector)
}

/// Used to monitor different types of connections. This type can be used for
/// frameworks to create wrappings for different types of connections.
///
@internal
pub type MonitorSelector {
  MonitorSelector(Selector(process.Down))
}

/// A convenient alias for a HTTP response with a `ResponseBody` as the body.
///
pub type Response =
  HttpResponse(ResponseBody)

fn transform_response_body(
  resp: Response,
) -> HttpResponse(ewe_http.ResponseBody) {
  response.set_body(resp, case resp.body {
    TextData(text) -> ewe_http.TextData(text)
    BytesData(bytes) -> ewe_http.BytesData(bytes)
    BitsData(bits) -> ewe_http.BitsData(bits)
    StringTreeData(string_tree) -> ewe_http.StringTreeData(string_tree)

    ChunkedData(yielder) -> ewe_http.ChunkedData(yielder)
    File(descriptor, offset, size) -> ewe_http.File(descriptor, offset, size)

    Websocket(MonitorSelector(selector)) -> ewe_http.Websocket(selector)
    SSE(MonitorSelector(selector)) -> ewe_http.SSE(selector)

    Empty -> ewe_http.Empty
  })
}

/// Possible errors that can occur when setting response body from a file.
///
pub type FileError {
  /// File does not exist.
  ///
  NoEntry
  /// Missing permission for reading the file, or for searching one of the
  /// parents directories.
  ///
  NoAccess
  /// The named file is a directory.
  ///
  IsDirectory
  /// Untypical file error.
  ///
  UnknownFileError(dynamic.Dynamic)
}

fn internal_to_file_error(error: file.FileError) -> FileError {
  case error {
    file.Enoent -> NoEntry
    file.Eacces -> NoAccess
    file.Eisdir -> IsDirectory
    file.Eunknown(error) -> UnknownFileError(error)
  }
}

/// Sets response body from file, sets `content-length` header.
///
pub fn file(
  path: String,
  offset offset: Option(Int),
  limit limit: Option(Int),
) -> Result(ResponseBody, FileError) {
  // TODO: handle invalid offset + limit?
  case file.open(path) {
    Ok(file) ->
      Ok(File(
        file.descriptor,
        offset: option.unwrap(offset, 0),
        size: option.unwrap(limit, file.size),
      ))
    Error(error) -> Error(internal_to_file_error(error))
  }
}

// -----------------------------------------------------------------------------
// BUILDER
// -----------------------------------------------------------------------------

type Handler =
  fn(Request) -> Response

type OnStart =
  fn(http.Scheme, SocketAddress) -> Nil

/// Ewe's server builder. Contains all server configurations. Can be adjusted
/// with the following functions:
/// - `ewe.bind`
/// - `ewe.bind_all`
/// - `ewe.listening`
/// - `ewe.listening_random`
/// - `ewe.enable_ipv6`
/// - `ewe.enable_tls`
/// - `ewe.with_name`
/// - `ewe.on_start`
/// - `ewe.quiet`
/// - `ewe.on_crash`
/// - `ewe.idle_timeout`
///
pub opaque type Builder {
  Builder(
    handler: Handler,
    port: Int,
    interface: String,
    ipv6: Bool,
    tls: Option(#(String, String)),
    on_start: OnStart,
    on_crash: Response,
    listener_name: process.Name(listener.Message),
    idle_timeout: Int,
  )
}

/// Creates new server builder with handler provided.
///
/// Default configuration:
/// - port: `8080`
/// - interface: `127.0.0.1`
/// - No ipv6 support
/// - No TLS support
/// - Default listener name for server information retrieval
/// - on_start: prints `Listening on <scheme>://<ip_address>:<port>`
/// - on_crash: empty 500 response
/// - idle_timeout: connection is closed after 10_000ms of inactivity
///
pub fn new(handler: Handler) -> Builder {
  Builder(
    handler:,
    port: 8080,
    interface: "127.0.0.1",
    ipv6: False,
    tls: None,
    on_start: fn(scheme, server) {
      let address = case server.ip {
        IpV6(..) -> "[" <> ip_address_to_string(server.ip) <> "]"
        IpV4(..) -> ip_address_to_string(server.ip)
      }

      let url =
        http.scheme_to_string(scheme)
        <> "://"
        <> address
        <> ":"
        <> int.to_string(server.port)

      logging.log(logging.Info, "Listening on " <> url)
    },
    on_crash: response.new(500) |> response.set_body(Empty),
    listener_name: process.new_name("glisten_listener"),
    idle_timeout: 10_000,
  )
}

/// Binds server to a specific interface. Crashes program if the interface is
/// invalid.
///
pub fn bind(builder: Builder, interface interface: String) -> Builder {
  Builder(..builder, interface:)
}

/// Binds server to all interfaces.
///
pub fn bind_all(builder: Builder) -> Builder {
  Builder(..builder, interface: "0.0.0.0")
}

/// Sets listening port for server.
///
pub fn listening(builder: Builder, port port: Int) -> Builder {
  Builder(..builder, port:)
}

/// Sets listening port for server to a random port. Useful for testing.
///
pub fn listening_random(builder: Builder) -> Builder {
  Builder(..builder, port: 0)
}

/// Enables IPv6 support.
///
pub fn enable_ipv6(builder: Builder) -> Builder {
  Builder(..builder, ipv6: True)
}

/// Enables TLS support, requires certificate and key file.
///
pub fn enable_tls(
  builder: Builder,
  certificate_file certificate_file: String,
  key_file key_file: String,
) -> Builder {
  let cert = case file.open(certificate_file) {
    Ok(_) -> certificate_file
    Error(_) -> panic as "Failed to find cert file"
  }

  let key = case file.open(key_file) {
    Ok(_) -> key_file
    Error(_) -> panic as "Failed to find key file"
  }

  Builder(..builder, tls: Some(#(cert, key)))
}

/// Sets a custom process name for server information retrieval, allowing to
/// use `ewe.get_server_info` after the server starts.
///
pub fn with_name(
  builder: Builder,
  name: process.Name(listener.Message),
) -> Builder {
  Builder(..builder, listener_name: name)
}

/// Sets a custom handler that will be called after server starts.
///
pub fn on_start(
  builder: Builder,
  on_start: fn(http.Scheme, SocketAddress) -> Nil,
) -> Builder {
  Builder(..builder, on_start:)
}

/// Sets an empty `on_start` function.
///
pub fn quiet(builder: Builder) -> Builder {
  Builder(..builder, on_start: fn(_, _) { Nil })
}

/// Sets a custom response that will be sent when server crashes.
///
pub fn on_crash(builder: Builder, on_crash: Response) -> Builder {
  Builder(..builder, on_crash:)
}

/// Sets a custom idle timeout in milliseconds for connections. If
/// provided timeout is less than 0, 10_000ms will be used instead.
///
pub fn idle_timeout(builder: Builder, idle_timeout: Int) -> Builder {
  case idle_timeout {
    idle_timeout if idle_timeout >= 0 -> Builder(..builder, idle_timeout:)
    _ -> Builder(..builder, idle_timeout: 10_000)
  }
}

// -----------------------------------------------------------------------------
// SERVER
// -----------------------------------------------------------------------------

/// Starts the server with the provided configuration.
///
pub fn start(
  builder: Builder,
) -> Result(actor.Started(Supervisor), actor.StartError) {
  let handler = fn(req) { transform_response_body(builder.handler(req)) }
  let on_crash = transform_response_body(builder.on_crash)

  let glisten_supervisor =
    glisten.new(
      handler.init,
      handler.loop(handler, on_crash, builder.idle_timeout),
    )
    |> glisten.bind(builder.interface)
    |> fn(glisten_builder) {
      case builder.ipv6 {
        True -> glisten.with_ipv6(glisten_builder)
        False -> glisten_builder
      }
    }
    |> fn(glisten_builder) {
      case builder.tls {
        Some(#(cert, key)) -> glisten.with_tls(glisten_builder, cert, key)
        None -> glisten_builder
      }
    }
    // https://github.com/rawhat/glisten/blob/master/src/glisten.gleam#L359
    |> glisten.start_with_listener_name(builder.port, builder.listener_name)
    |> result.map(fn(started) {
      let scheme = case builder.tls {
        Some(#(_, _)) -> http.Https
        None -> http.Http
      }

      let server_info = glisten.get_server_info(builder.listener_name, 10_000)
      let ip_address = glisten_to_ewe_ip(server_info.ip_address)

      let server = SocketAddress(ip: ip_address, port: server_info.port)

      builder.on_start(scheme, server)

      started
    })

  let glisten_child = supervision.supervisor(fn() { glisten_supervisor })

  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(glisten_child)
  |> supervisor.start()
}

/// Creates a supervisor with the provided configuration that is a child of a
/// supervision tree.
///
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start(builder) })
}

// -----------------------------------------------------------------------------
// REQUEST
// -----------------------------------------------------------------------------

/// Possible errors that can occur when reading a body.
///
pub type BodyError {
  /// Body is larger than the provided limit.
  BodyTooLarge
  /// Body is malformed.
  InvalidBody
}

/// A convenient alias for a HTTP request with a `Connection` as the body.
///
pub type Request =
  HttpRequest(Connection)

/// Reads body from the request. If request body is malformed, `InvalidBody`
/// error is returned. On success, returns a request with body converted to
/// `BitArray`.
///
/// - When `transfer-encoding` header set as `chunked`, `BodyTooLarge` error is
/// returned if accumulated body is larger than `size_limit`.
/// - Ensures that `content-length` is in `size_limit` scope.
///
pub fn read_body(
  req: Request,
  bytes_limit bytes_limit: Int,
) -> Result(HttpRequest(BitArray), BodyError) {
  case ewe_http.read_body(req, bytes_limit) {
    Ok(req) -> Ok(req)
    Error(ewe_http.BodyTooLarge) -> Error(BodyTooLarge)
    Error(_) -> Error(InvalidBody)
  }
}

/// A convenient alias for a consumer that reads `N` amount of bytes from the
/// request body stream.
///
pub type Consumer =
  fn(Int) -> Result(Stream, BodyError)

/// Used to track the progress of reading the request body stream.
///
pub type Stream {
  /// Chunk of data has been consumed.
  ///
  Consumed(data: BitArray, next: Consumer)
  /// Signifies that the request body stream has been fully consumed.
  ///
  Done
}

/// Returns the consumer function that reads `N` amount of bytes from the
/// request body stream.
///
pub fn stream_body(req: Request) -> Result(Consumer, BodyError) {
  case ewe_http.stream_body(req) {
    Ok(consumer) -> Ok(consumer_adapter(consumer))
    Error(_) -> Error(InvalidBody)
  }
}

fn consumer_adapter(
  internal_consumer: fn(Int) -> Result(ewe_http.Stream, ewe_http.ParseError),
) -> Consumer {
  fn(size) {
    case internal_consumer(size) {
      Ok(ewe_http.Done) -> Ok(Done)
      Ok(ewe_http.Consumed(data, next)) -> {
        Ok(Consumed(data, consumer_adapter(next)))
      }
      Error(_) -> Error(InvalidBody)
    }
  }
}

// -----------------------------------------------------------------------------
// WEBSOCKET
// -----------------------------------------------------------------------------

/// Represents a WebSocket connection between a client and a server.
///
pub type WebsocketConnection =
  ewe_ws.WebsocketConnection

/// Represents an instruction on how WebSocket connection should proceed.
///
/// - continue processing the WebSocket connection.
/// - continue processing the WebSocket connection with selector for custom
///   messages.
/// - stop the WebSocket connection.
/// - stop the WebSocket connection with abnormal reason.
///
pub opaque type WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Option(Selector(user_message)))
  WebsocketNormalStop
  WebsocketAbnormalStop(reason: String)
}

/// Instructs WebSocket connection to continue processing.
///
pub fn websocket_continue(
  user_state: user_state,
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, None)
}

/// Instructs WebSocket connection to continue processing, including selector
/// for custom messages.
///
pub fn websocket_continue_with_selector(
  user_state: user_state,
  selector: Selector(user_message),
) -> WebsocketNext(user_state, user_message) {
  WebsocketContinue(user_state, Some(selector))
}

/// Instructs WebSocket connection to stop.
///
pub fn websocket_stop() -> WebsocketNext(user_state, user_message) {
  WebsocketNormalStop
}

/// Instructs WebSocket connection to stop with abnormal reason.
///
pub fn websocket_stop_abnormal(
  reason: String,
) -> WebsocketNext(user_state, user_message) {
  WebsocketAbnormalStop(reason)
}

fn to_internal_websocket_next(
  next: WebsocketNext(user_state, user_message),
) -> ewe_ws.WebsocketNext(user_state, user_message) {
  case next {
    WebsocketContinue(user_state, selector) ->
      ewe_ws.Continue(user_state, selector)
    WebsocketNormalStop -> ewe_ws.NormalStop
    WebsocketAbnormalStop(reason) -> ewe_ws.AbnormalStop(reason)
  }
}

/// Represents a WebSocket message received from the client.
///
pub type WebsocketMessage(user_message) {
  /// Indicate that text frame has been received.
  ///
  Text(String)
  /// Indicate that binary frame has been received.
  ///
  Binary(BitArray)
  /// Indicate that user message has been received from WebSocket selector.
  ///
  User(user_message)
}

fn transform_websocket_message(
  message: ewe_ws.WebsocketMessage(user_message),
) -> Result(WebsocketMessage(user_message), Nil) {
  // NOTE: see "https://github.com/rawhat/gramps/pull/7"
  case message {
    ewe_ws.WebsocketFrame(ws.Data(frame)) -> {
      ws.match_data_frame(
        frame,
        on_text: fn(payload, _) {
          bit_array.to_string(payload) |> result.map(Text)
        },
        on_binary: fn(payload, _) { Ok(Binary(payload)) },
      )
    }
    ewe_ws.UserMessage(user_message) -> Ok(User(user_message))
    _ -> Error(Nil)
  }
}

/// Upgrade request to a WebSocket connection. If the initial request is not
/// valid for WebSocket upgrade, 400 response is sent.
///
/// `on_init` function is called once process that handles WebSocket connection
/// is initialized. It must return a tuple with initial state and selector for
/// custom messages. If there is no custom messages, user can pass the same
/// selector from the argument
///
/// `handler` function is called for every WebSocket message received. It must
/// return instruction on how WebSocket connection should proceed.
///
/// `on_close` function is called when WebSocket process is going to be stopped.
///
pub fn upgrade_websocket(
  req: Request,
  on_init on_init: fn(WebsocketConnection, Selector(user_message)) ->
    #(user_state, Selector(user_message)),
  handler handler: fn(
    WebsocketConnection,
    user_state,
    WebsocketMessage(user_message),
  ) ->
    WebsocketNext(user_state, user_message),
  on_close on_close: fn(WebsocketConnection, user_state) -> Nil,
) -> Response {
  let handler = fn(conn, state, msg) {
    transform_websocket_message(msg)
    |> result.map(handler(conn, state, _))
    |> result.unwrap(websocket_continue(state))
    |> to_internal_websocket_next()
  }

  let transport = req.body.transport
  let socket = req.body.socket

  case ewe_http.upgrade_websocket(req, transport, socket) {
    Ok(#(extensions, permessage_deflate)) -> {
      let started =
        ewe_ws.start(
          transport,
          socket,
          on_init,
          handler,
          on_close,
          extensions,
          permessage_deflate,
        )
      case started {
        Ok(selector) ->
          response.new(200)
          |> response.set_body(Websocket(MonitorSelector(selector)))
        Error(_) -> response.new(500) |> response.set_body(Empty)
      }
    }
    Error(_) -> response.new(400) |> response.set_body(Empty)
  }
}

/// Sends a binary frame to the websocket client.
///
pub fn send_binary_frame(
  conn: WebsocketConnection,
  bits: BitArray,
) -> Result(Nil, glisten.SocketReason) {
  ewe_ws.send_frame(
    ws.encode_binary_frame,
    conn.transport,
    conn.socket,
    conn.deflate,
    bits,
  )
}

/// Sends a text frame to the websocket client.
///
pub fn send_text_frame(
  conn: WebsocketConnection,
  text: String,
) -> Result(Nil, glisten.SocketReason) {
  ewe_ws.send_frame(
    ws.encode_text_frame,
    conn.transport,
    conn.socket,
    conn.deflate,
    text,
  )
}

// -----------------------------------------------------------------------------
// SERVER-SENT EVENT
// -----------------------------------------------------------------------------

/// Represents a Server-Sent Events connection between a client and a server.
///
pub type SSEConnection =
  ewe_sse.SSEConnection

/// Represents an instruction on how Server-Sent Events connection should
/// proceed.
///
/// - continue processing the Server-Sent Events connection.
/// - stop the Server-Sent Events connection.
/// - stop the Server-Sent Events connection with abnormal reason.
///
pub opaque type SSENext(user_state) {
  SSEContinue(user_state)
  SSENormalStop
  SSEAbnormalStop(reason: String)
}

/// Instructs Server-Sent Events connection to continue processing.
///
pub fn sse_continue(user_state: user_state) -> SSENext(user_state) {
  SSEContinue(user_state)
}

/// Instructs Server-Sent Events connection to stop.
///
pub fn sse_stop() -> SSENext(user_state) {
  SSENormalStop
}

/// Instructs Server-Sent Events connection to stop with abnormal reason.
///
pub fn sse_stop_abnormal(reason: String) -> SSENext(user_state) {
  SSEAbnormalStop(reason)
}

fn to_internal_sse_next(
  next: SSENext(user_state),
) -> ewe_sse.SSENext(user_state) {
  case next {
    SSEContinue(user_state) -> ewe_sse.Continue(user_state)
    SSENormalStop -> ewe_sse.NormalStop
    SSEAbnormalStop(reason) -> ewe_sse.AbnormalStop(reason)
  }
}

/// Represents a Server-Sent Events event. The event fields are:
/// - `event`: a string identifying the type of event described.
/// - `data`: the data field for the message.
/// - `id`: event ID.
/// - `retry`: The reconnection time. If the connection to the server is lost,
/// the browser will wait for the specified time before attempting to reconnect.
/// 
/// Can be created using `ewe.event` and modified with `ewe.event_name`,
/// `ewe.event_id`, and `ewe.event_retry`.
///
pub type SSEEvent =
  ewe_sse.SSEEvent

/// Creates a new SSE event with the given data. Use `ewe.event_name`,
/// `ewe.event_id`, and `ewe.event_retry` to modify other fields of the event.
///
pub fn event(data: String) -> SSEEvent {
  ewe_sse.SSEEvent(event: None, data:, id: None, retry: None)
}

/// Sets the name of the event.
///
pub fn event_name(event: SSEEvent, name: String) -> SSEEvent {
  ewe_sse.SSEEvent(..event, event: Some(name))
}

/// Sets the ID of the event.
///
pub fn event_id(event: SSEEvent, id: String) -> SSEEvent {
  ewe_sse.SSEEvent(..event, id: Some(id))
}

/// Sets the retry time of the event.
///
pub fn event_retry(event: SSEEvent, retry: Int) -> SSEEvent {
  ewe_sse.SSEEvent(..event, retry: Some(retry))
}

/// Sets up the connection for Server-Sent Events.
///
/// `on_init` function is called once process that handles SSE connection
/// is initialized. The argument is subject that can be used to send messages
/// to the client. It must return initial state.
///
/// `handler` function is called for every subject's message received. It must
/// return instruction on how SSE connection should proceed.
/// 
/// `on_close` function is called when SSE process is going to be stopped.
///
pub fn sse(
  req: Request,
  on_init on_init: fn(Subject(user_message)) -> user_state,
  handler handler: fn(SSEConnection, user_state, user_message) ->
    SSENext(user_state),
  on_close on_close: fn(SSEConnection, user_state) -> Nil,
) {
  let handler = fn(conn, state, msg) {
    handler(conn, state, msg)
    |> to_internal_sse_next()
  }

  let transport = req.body.transport
  let socket = req.body.socket

  case ewe_sse.send_response(transport, socket) {
    Ok(Nil) -> {
      case ewe_sse.start(transport, socket, on_init, handler, on_close) {
        Ok(selector) -> {
          response.new(200)
          |> response.set_body(SSE(MonitorSelector(selector)))
        }
        Error(_) -> response.new(400) |> response.set_body(Empty)
      }
    }
    Error(Nil) -> response.new(400) |> response.set_body(Empty)
  }
}

/// Sends a Server-Sent Events event to the client.
///
pub fn send_event(
  conn: SSEConnection,
  event: SSEEvent,
) -> Result(Nil, glisten.SocketReason) {
  ewe_sse.send_event(conn.transport, conn.socket, event)
}
