import gleam/http.{Get, Post}
import notyet/task
import notyet/web.{type Context}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req)

  case wisp.path_segments(req), req.method {
    ["tasks"], Post -> task.create(req, ctx)
    ["tasks"], _ -> wisp.method_not_allowed([Post])
    ["tasks", key], Get -> task.read(req, ctx, key)
    ["tasks", _], _ -> wisp.method_not_allowed([Get])
    _, _ -> wisp.not_found()
  }
}
