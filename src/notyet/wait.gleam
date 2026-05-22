import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import notyet/wait/batch
import notyet/wait/duration as duration_parser
import notyet/wait/json_value.{type JsonValue}
import notyet/wait/record
import notyet/wait/sql
import notyet/wait/status
import notyet/wait/view
import notyet/web.{type Context}
import pog
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
          case batch.enqueue(ctx.batch, row, ctx.enqueue_timeout_ms) {
            Ok(_) ->
              json.object([#("status", json.string(status.to_string(status.Accepted)))])
              |> json.to_string
              |> wisp.json_response(202)
            // Shed: real client demand exceeded admission. 429 + Retry-After
            // tells the client to back off; the Idempotency-Key makes the
            // retry safe (it never creates a second row).
            Error(_) ->
              wisp.response(429)
              |> wisp.set_header("retry-after", "1")
          }
        }
      }
    }
  }
}

pub fn read(req: Request, ctx: Context, key: String) -> Response {
  use <- wisp.require_method(req, Get)

  case sql.get_wait_by_idempotency_key(ctx.db, key) {
    Ok(pog.Returned(_, [row])) ->
      row
      |> row_to_wait
      |> view.encode
      |> json.to_string
      |> wisp.json_response(200)
    // idempotency_key is UNIQUE, so the result is 0 or 1 row.
    Ok(pog.Returned(_, _)) -> wisp.not_found()
    Error(_) -> wisp.internal_server_error()
  }
}

/// Map a persisted row into the read-model. The row is written only by this
/// service through a schema with a UNIQUE key, a status CHECK, RFC3339
/// timestamps, and object-or-empty `data`, so the conversions are total against
/// stored data — hence `let assert`.
fn row_to_wait(row: sql.GetWaitByIdempotencyKeyRow) -> view.Wait {
  let assert Ok(id) = uuid.from_string(row.id)
  let assert Ok(activity) = uuid.from_string(row.activity)
  let assert Ok(wait_status) = status.from_string(row.status)
  let assert Ok(wait_until) = timestamp.parse_rfc3339(row.wait_until)
  let assert Ok(created_at) = timestamp.parse_rfc3339(row.created_at)
  view.Wait(
    id: id,
    activity: activity,
    idempotency_key: row.idempotency_key,
    status: wait_status,
    for_duration: row.for_duration,
    wait_until: wait_until,
    created_at: created_at,
    data: decode_data(row.data),
  )
}

/// `data` is the JSON object text, or `""` (the empty-string sentinel the read
/// query emits for SQL NULL via COALESCE).
fn decode_data(text: String) -> Option(JsonValue) {
  case text {
    "" -> None
    json_text -> {
      let assert Ok(value) = json.parse(json_text, json_value.decoder())
      Some(value)
    }
  }
}
