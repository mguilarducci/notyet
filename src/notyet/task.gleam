import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import notyet/task/batch
import notyet/task/duration as duration_parser
import notyet/task/record
import notyet/task/sql
import notyet/task/status
import notyet/task/view
import notyet/validate
import notyet/web.{type Context}
import pog
import wisp.{type Request, type Response}
import youid/uuid

const idempotency_header = "idempotency-key"

pub type TaskRequest {
  TaskRequest(duration: Duration, raw_wait_for: String, destination: String)
}

/// Decodes the "wait_for" field into both the parsed duration and its raw string.
fn wait_for_decoder() -> decode.Decoder(#(Duration, String)) {
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(#(d, s))
    Error(_) -> decode.failure(#(duration.empty, ""), "valid duration string")
  }
}

fn destination_decoder() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case validate.url_http(s) {
    Ok(url) -> decode.success(url)
    Error(_) -> decode.failure("", "destination must be an http(s) URL")
  }
}

pub fn task_decoder() -> decode.Decoder(TaskRequest) {
  use parsed <- decode.field("wait_for", wait_for_decoder())
  use destination <- decode.field("destination", destination_decoder())
  decode.success(TaskRequest(
    duration: parsed.0,
    raw_wait_for: parsed.1,
    destination: destination,
  ))
}

pub fn create(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)

  case request.get_header(req, idempotency_header) {
    Error(_) -> wisp.unprocessable_content()
    Ok(raw_key) ->
      // The Idempotency-Key must be a UUID v4: a single, URL-safe path segment,
      // so `GET /tasks/{key}` can round-trip it. Store the canonical form so a
      // repeat with different casing still deduplicates.
      case validate.uuid_v4(raw_key) {
        Error(_) -> wisp.unprocessable_content()
        Ok(key_uuid) -> create_with_key(req, ctx, uuid.to_string(key_uuid))
      }
  }
}

fn create_with_key(req: Request, ctx: Context, key: String) -> Response {
  use body <- wisp.require_json(req)
  case decode.run(body, task_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(tr) -> {
      let now = timestamp.system_time()
      let wait_until = timestamp.add(now, tr.duration)
      let row =
        record.TaskRecord(
          id: uuid.v4(),
          idempotency_key: key,
          wait_for: tr.raw_wait_for,
          destination: tr.destination,
          visible_at: wait_until,
          wait_until: wait_until,
          created_at: now,
        )
      case batch.enqueue(ctx.batch, row, ctx.enqueue_timeout_ms) {
        Ok(_) ->
          json.object([
            #("status", json.string(status.to_string(status.Pending))),
          ])
          |> json.to_string
          |> wisp.json_response(202)
        // Shed: real client demand exceeded admission. 429 + Retry-After tells
        // the client to back off; the Idempotency-Key makes the retry safe (it
        // never creates a second row).
        Error(_) ->
          wisp.response(429)
          |> wisp.set_header("retry-after", "1")
      }
    }
  }
}

pub fn read(req: Request, ctx: Context, key: String) -> Response {
  use <- wisp.require_method(req, Get)

  // The key is a UUID v4 (enforced on write); a non-v4 path segment cannot
  // identify any stored task. Match on the canonical form so casing differences
  // still resolve.
  case validate.uuid_v4(key) {
    Error(_) -> wisp.not_found()
    Ok(key_uuid) -> read_by_key(ctx, uuid.to_string(key_uuid))
  }
}

fn read_by_key(ctx: Context, key: String) -> Response {
  case sql.get_task_by_idempotency_key(ctx.db, key) {
    Ok(pog.Returned(_, [row])) ->
      row
      |> row_to_task
      |> view.encode
      |> json.to_string
      |> wisp.json_response(200)
    // idempotency_key is UNIQUE, so the result is 0 or 1 row.
    Ok(pog.Returned(_, _)) -> wisp.not_found()
    Error(_) -> wisp.internal_server_error()
  }
}

/// Map a persisted row into the read-model. The row is written only by this
/// service through a schema with a UNIQUE key, a status CHECK, and RFC3339
/// timestamps, so the conversions are total against stored data — hence `let assert`.
fn row_to_task(row: sql.GetTaskByIdempotencyKeyRow) -> view.Task {
  let assert Ok(id) = uuid.from_string(row.id)
  let assert Ok(task_status) = status.from_string(row.status)
  let assert Ok(wait_until) = timestamp.parse_rfc3339(row.wait_until)
  let assert Ok(created_at) = timestamp.parse_rfc3339(row.created_at)
  view.Task(
    id: id,
    idempotency_key: row.idempotency_key,
    status: task_status,
    wait_for: row.wait_for,
    wait_until: wait_until,
    created_at: created_at,
    destination: row.destination,
  )
}
