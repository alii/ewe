import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision

pub type Message(a) {
  GetInfo(reply_to: process.Subject(Result(a, Nil)))
  SetInfo(info: a)
  Shutdown
}

pub fn start_worker(
  name: process.Name(Message(a)),
) -> supervision.ChildSpecification(process.Subject(Message(a))) {
  let info_actor =
    actor.new(option.None)
    |> actor.on_message(fn(state, msg) {
      case msg {
        GetInfo(reply_to) -> {
          actor.send(reply_to, option.to_result(state, Nil))
          actor.continue(state)
        }
        SetInfo(server) -> actor.continue(option.Some(server))
        Shutdown -> actor.stop()
      }
    })
    |> actor.named(name)
    |> actor.start()

  supervision.worker(fn() { info_actor })
}

pub fn get(subject: process.Subject(Message(a))) -> Result(a, Nil) {
  actor.call(subject, 10_000, GetInfo)
}

pub fn set(subject: process.Subject(Message(a)), info: a) -> Nil {
  actor.send(subject, SetInfo(info))
}
