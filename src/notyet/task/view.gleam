import gleam/json
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import notyet/task/status.{type Status}
import youid/uuid.{type Uuid}

/// The read-back shape of a task. Pure: no `sql`/`pog` dependency, so `encode`
/// is unit-testable without a database. The handler maps a persisted row into
/// this before encoding.
pub type Task {
  Task(
    id: Uuid,
    idempotency_key: String,
    status: Status,
    wait_for: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}

/// Serialize a `Task` to the `200` response body. Timestamps are RFC3339, UTC.
pub fn encode(task: Task) -> json.Json {
  json.object([
    #("id", json.string(uuid.to_string(task.id))),
    #("idempotency_key", json.string(task.idempotency_key)),
    #("status", json.string(status.to_string(task.status))),
    #("wait_for", json.string(task.wait_for)),
    #("wait_until", json.string(rfc3339(task.wait_until))),
    #("created_at", json.string(rfc3339(task.created_at))),
  ])
}

fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
