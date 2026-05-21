import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import notyet/wait/status.{type Status}
import youid/uuid.{type Uuid}

/// A fully-formed wait ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer.
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

/// The canonical persisted wait the batch writer returns to a waiter. On a
/// dedup hit this is the ORIGINAL row, not the values the retry minted.
pub type PersistedWait {
  PersistedWait(
    id: Uuid,
    activity: Uuid,
    status: Status,
    created_at: Timestamp,
    wait_until: Timestamp,
  )
}
