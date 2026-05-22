import gleam/http.{Get, Post}
import notyet/wait
import notyet/web.{type Context}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req)

  case wisp.path_segments(req), req.method {
    ["wait"], Post -> wait.create(req, ctx)
    ["wait"], _ -> wisp.method_not_allowed([Post])
    ["wait", key], Get -> wait.read(req, ctx, key)
    ["wait", _], _ -> wisp.method_not_allowed([Get])
    _, _ -> wisp.not_found()
  }
}
