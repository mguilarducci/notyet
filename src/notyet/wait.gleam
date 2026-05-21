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
import youid/uuid.{type Uuid}

pub type WaitRequest {
  WaitRequest(
    duration: Duration,
    raw_for: String,
    activity: Uuid,
    data: Option(JsonValue),
  )
}

/// Decodes the "for" field into both the parsed duration and its raw string.
fn for_decoder() -> decode.Decoder(#(Duration, String)) {
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(#(d, s))
    Error(_) -> decode.failure(#(duration.empty, ""), "valid duration string")
  }
}

/// Decodes "activity" as a strict UUID v4. Non-string, non-UUID, or non-v4 fail.
fn activity_decoder() -> decode.Decoder(Uuid) {
  use s <- decode.then(decode.string)
  case uuid.from_string(s) {
    Ok(u) ->
      case uuid.version(u) == uuid.V4 {
        True -> decode.success(u)
        False -> decode.failure(uuid.v4(), "activity must be a UUID v4")
      }
    Error(_) -> decode.failure(uuid.v4(), "activity must be a UUID v4")
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use parsed <- decode.field("for", for_decoder())
  use activity <- decode.field("activity", activity_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    json_value.object_decoder() |> decode.map(Some),
  )
  decode.success(WaitRequest(
    duration: parsed.0,
    raw_for: parsed.1,
    activity: activity,
    data: data,
  ))
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
    Ok(WaitRequest(duration: d, raw_for: _, activity: _, data: _)) -> {
      let now = timestamp.system_time()
      let for_time = timestamp.add(now, d)

      uuid.v4_string()
      |> encode_response(now, for_time)
      |> json.to_string
      |> wisp.json_response(201)
    }
  }
}
