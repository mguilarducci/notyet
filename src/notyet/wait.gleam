import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import notyet/wait/batch
import notyet/wait/duration as duration_parser
import notyet/wait/json_value.{type JsonValue}
import notyet/wait/record
import notyet/wait/status
import notyet/web.{type Context}
import wisp.{type Request, type Response}
import youid/uuid.{type Uuid}

const idempotency_header = "idempotency-key"

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

pub fn encode_response(p: record.PersistedWait) -> json.Json {
  json.object([
    #("id", json.string(uuid.to_string(p.id))),
    #("activity", json.string(uuid.to_string(p.activity))),
    #("status", json.string(status.to_string(p.status))),
    #(
      "created_at",
      json.string(timestamp.to_rfc3339(p.created_at, calendar.utc_offset)),
    ),
    #(
      "for",
      json.string(timestamp.to_rfc3339(p.wait_until, calendar.utc_offset)),
    ),
  ])
}

pub fn create(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)

  case request.get_header(req, idempotency_header) {
    Error(_) -> wisp.unprocessable_content()
    Ok("") -> wisp.unprocessable_content()
    Ok(key) -> {
      use body <- wisp.require_json(req)
      case decode.run(body, wait_decoder()) {
        Error(_) -> wisp.unprocessable_content()
        Ok(wr) -> {
          let now = timestamp.system_time()
          let row =
            record.WaitRecord(
              id: uuid.v4(),
              activity: wr.activity,
              idempotency_key: key,
              data: wr.data,
              for_duration: wr.raw_for,
              wait_until: timestamp.add(now, wr.duration),
              created_at: now,
            )
          case batch.enqueue(ctx.batch, row, ctx.ack_timeout_ms) {
            Ok(persisted) ->
              persisted
              |> encode_response
              |> json.to_string
              |> wisp.json_response(201)
            Error(_) -> wisp.internal_server_error()
          }
        }
      }
    }
  }
}
