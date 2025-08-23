// TODO: fill docs

import ewe/internal/http as http_
import ewe/internal/response as response_
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import glisten
import glisten/transport

pub type Connection =
  http_.Connection

pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub fn ip_address_to_string(address: IpAddress) -> String {
  convert_to_glisten_ip(address)
  |> glisten.ip_address_to_string()
}

fn convert_to_ewe_ip(ip: glisten.IpAddress) -> IpAddress {
  case ip {
    glisten.IpV4(n1, n2, n3, n4) -> IpV4(n1, n2, n3, n4)
    glisten.IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

fn convert_to_glisten_ip(ip: IpAddress) -> glisten.IpAddress {
  case ip {
    IpV4(n1, n2, n3, n4) -> glisten.IpV4(n1, n2, n3, n4)
    IpV6(n1, n2, n3, n4, n5, n6, n7, n8) ->
      glisten.IpV6(n1, n2, n3, n4, n5, n6, n7, n8)
  }
}

pub opaque type Builder {
  // TODO: tls
  Builder(
    handler: http_.Handler,
    port: Int,
    interface: String,
    ipv6: Bool,
    on_start: fn(http.Scheme, IpAddress, Int) -> Nil,
  )
}

pub fn new(handler: http_.Handler) -> Builder {
  Builder(
    handler:,
    port: 8080,
    interface: "127.0.0.1",
    ipv6: False,
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

pub fn port(builder: Builder, port: Int) -> Builder {
  Builder(..builder, port:)
}

pub fn bind(builder: Builder, interface: String) -> Builder {
  Builder(..builder, interface:)
}

pub fn bind_all(builder: Builder) -> Builder {
  Builder(..builder, interface: "0.0.0.0")
}

pub fn ipv6(builder: Builder) -> Builder {
  Builder(..builder, ipv6: True)
}

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
  // https://github.com/rawhat/glisten/blob/master/src/glisten.gleam#L359
  |> glisten.start_with_listener_name(builder.port, name)
  |> result.map(fn(started) {
    let server_info = glisten.get_server_info(name, 10_000)
    // TODO: tls
    let scheme = http.Http
    let ip_address = convert_to_ewe_ip(server_info.ip_address)

    builder.on_start(scheme, ip_address, server_info.port)

    started
  })
}

pub fn supervised(
  builder: Builder,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() { start(builder) })
}

pub fn read_body(req: Request(Connection)) -> Result(Request(BitArray), Nil) {
  http_.read_body(req) |> result.replace_error(Nil)
}
