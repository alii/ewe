import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
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
import ewe/internal/http as http_
import ewe/internal/response as response_

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
pub fn client_stats(connection: Connection) -> Result(#(IpAddress, Int), Nil) {
  transport.peername(connection.transport, connection.socket)
  |> result.map(fn(tuple) {
    let #(ip, port) = tuple
    #(glisten_options_to_ewe_ip(ip), port)
  })
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
/// - `ewe.with_ipv6`
/// - `ewe.with_tls`
/// - `ewe.on_start`
pub opaque type Builder {
  Builder(
    handler: http_.Handler,
    port: Int,
    interface: String,
    ipv6: Bool,
    tls: Option(#(String, String)),
    on_start: fn(http.Scheme, IpAddress, Int) -> Nil,
  )
}

/// Creates new server builder with handler provided.
/// 
/// Default configuration:
/// - port: `8080`
/// - interface: `127.0.0.1`
/// - No ipv6 support
/// - No TLS support
/// - on_start: prints `Listening on <scheme>://<ip_address>:<port>`
pub fn new(handler: http_.Handler) -> Builder {
  Builder(
    handler:,
    port: 8080,
    interface: "127.0.0.1",
    ipv6: False,
    tls: None,
    on_start: fn(scheme, ip_address, port) {
      let address = case ip_address {
        IpV6(..) -> "[" <> ip_address_to_string(ip_address) <> "]"
        IpV4(..) -> ip_address_to_string(ip_address)
      }

      let url =
        http.scheme_to_string(scheme)
        <> "://"
        <> address
        <> ":"
        <> int.to_string(port)

      io.println("Listening on " <> url)
    },
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

/// Sets a custom handler that will be called after server starts.
pub fn on_start(
  builder: Builder,
  on_start: fn(http.Scheme, IpAddress, Int) -> Nil,
) -> Builder {
  Builder(..builder, on_start:)
}

/// Starts the server.
pub fn start(
  builder: Builder,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  let name = process.new_name("ewe_glisten")

  glisten.new(
    fn(conn) { #(http_.transform_connection(conn), None) },
    fn(http_conn, msg, conn) {
      let assert glisten.Packet(msg) = msg
      case http_.parse_request(http_conn, msg) {
        Ok(http_.ParsedRequest(request, version)) -> {
          let resp =
            builder.handler(request)
            |> response_.append_default_headers(version)
            |> response_.encode()

          case transport.send(conn.transport, conn.socket, resp) {
            Ok(Nil) -> glisten.continue(http_conn)
            Error(_) -> glisten.stop()
          }
        }
        Error(_) -> glisten.stop()
      }
    },
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

    builder.on_start(scheme, ip_address, server_info.port)

    started
  })
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
