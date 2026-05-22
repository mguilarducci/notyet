import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import youid/uuid.{type Uuid}

/// A fully-formed wait ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. Fire-and-forget: nothing
/// is returned to the caller — the 202 is an enqueue ack, not a persisted row.
pub type WaitRecord {
  WaitRecord(
    id: Uuid,
    activity: Uuid,
    idempotency_key: String,
    data: Option(JsonValue),
    for_duration: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
