import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import glisten
import glisten/socket/options as glisten_options
import glisten/transport

import ewe/internal/file as file_
import ewe/internal/handler as handler_
import ewe/internal/http as http_
import ewe/internal/info as info_

/// Represents a connection between a client and a server, stored inside a `Request`.
/// Can be converted to a `BitArray` using `ewe.read_body`.
pub type Connection =
  http_.Connection

/// Represents an IP address. Appears when accessing client's information (`ewe.client_stats`) or `on_start` handler (`ewe.on_start`).
pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// Converts an `IpAddress` to a string for later printing.
pub fn ip_address_to_string(address: IpAddress) -> String {
  ewe_to_glisten_ip(address)
  |> glisten.ip_address_to_string()
}

/// Performs an attempt to get the client's IP address and port.
pub fn get_client_info(connection: Connection) -> Result(#(IpAddress, Int), Nil) {
  transport.peername(connection.transport, connection.socket)
  |> result.map(fn(tuple) {
    let #(ip, port) = tuple
    #(glisten_options_to_ewe_ip(ip), port)
  })
}

/// Retrieves server's information. Requires the same name as the one used in `ewe.with_name` and server to be started. Otherwise, will crash the program.
pub fn get_server_info(
  name: process.Name(info_.Message(ServerInfo)),
) -> Result(ServerInfo, Nil) {
  info_.get(process.named_subject(name))
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

/// Ewe's server builder. Contains all server's configuration. Can be adjusted
/// with the following functions:
/// - `ewe.bind`
/// - `ewe.bind_all`
/// - `ewe.with_port`
/// - `ewe.with_random_port`
/// - `ewe.with_ipv6`
/// - `ewe.with_tls`
/// - `ewe.with_name`
/// - `ewe.on_start`
/// - `ewe.on_crash`
pub opaque type Builder {
  Builder(
    handler: http_.Handler,
    port: Int,
    interface: String,
    ipv6: Bool,
    tls: Option(#(String, String)),
    on_start: fn(ServerInfo) -> Nil,
    on_crash: response.Response(bytes_tree.BytesTree),
    info_worker_name: process.Name(info_.Message(ServerInfo)),
  )
}

/// Represents started server's information. Can be retrieved using `ewe.get_server_info`.
pub type ServerInfo {
  ServerInfo(scheme: http.Scheme, ip_address: IpAddress, port: Int)
}

/// Creates new server builder with handler provided.
/// 
/// Default configuration:
/// - port: `8080`
/// - interface: `127.0.0.1`
/// - No ipv6 support
/// - No TLS support
/// - Default process name for server information retrieval
/// - on_start: prints `Listening on <scheme>://<ip_address>:<port>`
/// - on_crash: empty 500 response
pub fn new(handler: http_.Handler) -> Builder {
  Builder(
    handler:,
    port: 8080,
    interface: "127.0.0.1",
    ipv6: False,
    tls: None,
    on_start: fn(server) {
      let address = case server.ip_address {
        IpV6(..) -> "[" <> ip_address_to_string(server.ip_address) <> "]"
        IpV4(..) -> ip_address_to_string(server.ip_address)
      }

      let url =
        http.scheme_to_string(server.scheme)
        <> "://"
        <> address
        <> ":"
        <> int.to_string(server.port)

      io.println("Listening on " <> url)
    },
    on_crash: response.new(500) |> response.set_body(bytes_tree.new()),
    info_worker_name: process.new_name("ewe_server_info"),
  )
}

/// Binds server to a specific interface. Crashes program if interface is invalid.
pub fn bind(builder: Builder, interface: String) -> Builder {
  Builder(..builder, interface:)
}

/// Binds server to all interfaces.
pub fn bind_all(builder: Builder) -> Builder {
  Builder(..builder, interface: "0.0.0.0")
}

/// Sets listening port for server.
pub fn with_port(builder: Builder, port: Int) -> Builder {
  Builder(..builder, port:)
}

/// Sets listening port for server to a random port. Useful for testing.
pub fn with_random_port(builder: Builder) -> Builder {
  Builder(..builder, port: 0)
}

/// Enables IPv6 support.
pub fn with_ipv6(builder: Builder) -> Builder {
  Builder(..builder, ipv6: True)
}

/// Enables TLS support, requires certificate and key file.
pub fn with_tls(
  builder: Builder,
  certificate: String,
  keyfile: String,
) -> Builder {
  let cert = case file_.open(certificate) {
    Ok(_) -> certificate
    Error(_) -> panic as "Failed to find cert file"
  }

  let key = case file_.open(keyfile) {
    Ok(_) -> keyfile
    Error(_) -> panic as "Failed to find key file"
  }

  Builder(..builder, tls: Some(#(cert, key)))
}

/// Sets a custom process name for server information retrieval, allowing to use `ewe.get_server_info` after server starts.
pub fn with_name(
  builder: Builder,
  name: process.Name(info_.Message(ServerInfo)),
) -> Builder {
  Builder(..builder, info_worker_name: name)
}

/// Sets a custom handler that will be called after server starts.
pub fn on_start(builder: Builder, on_start: fn(ServerInfo) -> Nil) -> Builder {
  Builder(..builder, on_start:)
}

/// Sets a custom response that will be sent when server crashes.
pub fn on_crash(
  builder: Builder,
  on_crash: response.Response(bytes_tree.BytesTree),
) -> Builder {
  Builder(..builder, on_crash:)
}

/// Starts the server.
pub fn start(
  builder: Builder,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let name = process.new_name("ewe_glisten")

  let worker_name = builder.info_worker_name
  let subject = process.named_subject(worker_name)
  let info_worker = info_.start_worker(worker_name)

  let glisten_supervisor =
    glisten.new(
      fn(conn) { #(http_.transform_connection(conn), None) },
      handler_.loop(builder.handler, builder.on_crash),
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
    |> glisten.start_with_listener_name(builder.port, name)
    |> result.map(fn(started) {
      let scheme = case builder.tls {
        Some(#(_, _)) -> http.Https
        None -> http.Http
      }

      let server_info = glisten.get_server_info(name, 10_000)
      let ip_address = glisten_to_ewe_ip(server_info.ip_address)

      let server =
        ServerInfo(
          scheme: scheme,
          ip_address: ip_address,
          port: server_info.port,
        )

      info_.set(subject, server)

      started
    })

  let glisten_child = supervision.supervisor(fn() { glisten_supervisor })

  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(glisten_child)
  |> supervisor.add(info_worker)
  |> supervisor.start()
}

/// Creates a supervisor that can be appended to a supervision tree.
pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start(builder) })
}

/// Possible errors that can occur when reading a body.
pub type BodyError {
  BodyTooLarge
  InvalidBody
}

/// Reads body from a request. If request body is malformed, `InvalidBody` error is returned. On success, returns a request with body converted to `BitArray`.
/// - When `transfer-encoding` header set as `chunked`, `BodyTooLarge` error is returned if
/// accumulated body is larger than `size_limit`.
/// - Ensures that `content-length` is in `size_limit` scope.
pub fn read_body(
  req: Request(Connection),
  size_limit size_limit: Int,
) -> Result(Request(BitArray), BodyError) {
  case http_.read_body(req, size_limit) {
    Ok(req) -> Ok(req)
    Error(http_.BodyTooLarge) -> Error(BodyTooLarge)
    Error(_) -> Error(InvalidBody)
  }
}
