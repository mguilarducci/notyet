import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import notyet/wait/status.{type Status}
import youid/uuid.{type Uuid}

/// The read-back shape of a wait. Pure: no `sql`/`pog` dependency, so `encode`
/// is unit-testable without a database. The handler maps a persisted row into
/// this before encoding.
pub type Wait {
  Wait(
    id: Uuid,
    activity: Uuid,
    idempotency_key: String,
    status: Status,
    for_duration: String,
    wait_until: Timestamp,
    created_at: Timestamp,
    data: Option(JsonValue),
  )
}

/// Serialize a `Wait` to the `200` response body. `data` is omitted entirely
/// when absent (symmetric with the optional `data` on write). Timestamps are
/// RFC3339, UTC.
pub fn encode(wait: Wait) -> json.Json {
  let base = [
    #("id", json.string(uuid.to_string(wait.id))),
    #("activity", json.string(uuid.to_string(wait.activity))),
    #("idempotency_key", json.string(wait.idempotency_key)),
    #("status", json.string(status.to_string(wait.status))),
    #("for", json.string(wait.for_duration)),
    #("wait_until", json.string(rfc3339(wait.wait_until))),
    #("created_at", json.string(rfc3339(wait.created_at))),
  ]
  let fields = case wait.data {
    Some(value) -> list.append(base, [#("data", json_value.encode(value))])
    None -> base
  }
  json.object(fields)
}

fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
