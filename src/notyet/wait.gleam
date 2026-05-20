import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/duration as duration_parser
import notyet/wait/json_value.{type JsonValue}
import notyet/web.{type Context}
import wisp.{type Request, type Response}
import youid/uuid

pub type WaitRequest {
  WaitRequest(duration: Duration, data: Option(JsonValue))
}

fn duration_decoder() -> decode.Decoder(Duration) {
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(d)
    Error(_) -> decode.failure(duration.empty, "valid duration string")
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use parsed <- decode.field("for", duration_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    json_value.object_decoder() |> decode.map(Some),
  )
  decode.success(WaitRequest(duration: parsed, data: data))
}

pub fn encode_response(
  id: String,
  created_at: Timestamp,
  for_time: Timestamp,
) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("status", json.string("waiting")),
    #(
      "created_at",
      json.string(timestamp.to_rfc3339(created_at, calendar.utc_offset)),
    ),
    #("for", json.string(timestamp.to_rfc3339(for_time, calendar.utc_offset))),
  ])
}

pub fn create(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use body <- wisp.require_json(req)

  case decode.run(body, wait_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(WaitRequest(duration: d, data: _)) -> {
      let now = timestamp.system_time()
      let for_time = timestamp.add(now, d)

      uuid.v4_string()
      |> encode_response(now, for_time)
      |> json.to_string
      |> wisp.json_response(201)
    }
  }
}
