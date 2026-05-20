import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/json
import notyet/web.{type Context}
import wisp.{type Request, type Response}
import youid/uuid

pub type WaitRequest {
  WaitRequest(wait: String)
}

fn non_empty_string() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case s {
    "" -> decode.failure("", "non-empty string")
    _ -> decode.success(s)
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use wait <- decode.field("wait", non_empty_string())
  decode.success(WaitRequest(wait:))
}

pub fn encode_response(id: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("status", json.string("waiting")),
  ])
}

pub fn create(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use body <- wisp.require_json(req)

  case decode.run(body, wait_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(_) ->
      uuid.v4_string()
      |> encode_response
      |> json.to_string
      |> wisp.json_response(201)
  }
}
