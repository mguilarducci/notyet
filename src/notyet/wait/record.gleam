import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import youid/uuid.{type Uuid}

/// A fully-formed wait ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. There is no longer a
/// returned-row type: the write path is fire-and-forget (no row in the 202).
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
