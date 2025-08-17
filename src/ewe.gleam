import gleam/result
import glisten/socket
import glisten/socket/options
import glisten/tcp

pub fn main() -> Nil {
  let _ = start()

  Nil
}

fn start() -> Result(Nil, socket.SocketReason) {
  use listener <- result.try(
    tcp.listen(42_069, [options.ActiveMode(options.Passive)]),
  )

  loop(listener)
}

fn loop(listener: socket.ListenSocket) -> Result(Nil, socket.SocketReason) {
  use socket <- result.try(tcp.accept(listener))
  use msg <- result.try(tcp.receive(socket, 0))

  echo msg as "Message:"

  case tcp.close(socket) {
    Ok(Nil) -> loop(listener)
    Error(reason) -> Error(reason)
  }
}
