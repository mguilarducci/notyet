import gleam/erlang/process
import notyet/wait/batch
import wisp

pub type Context {
  Context(batch: process.Subject(batch.Message), enqueue_timeout_ms: Int)
}

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  handle_request(req)
}
