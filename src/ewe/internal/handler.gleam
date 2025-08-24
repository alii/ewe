import ewe/internal/http as http_
import gleam/http/request

// TODO: Handle http parsing errors 
pub fn run_handler(
  req: request.Request(http_.Connection),
  handler: http_.Handler,
  version: http_.HttpVersion,
) {
  todo
}
