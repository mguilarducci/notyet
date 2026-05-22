import gleam/time/timestamp.{type Timestamp}
import youid/uuid.{type Uuid}

/// A fully-formed task ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. Fire-and-forget: nothing
/// is returned to the caller — the 202 is an enqueue ack, not a persisted row.
pub type TaskRecord {
  TaskRecord(
    id: Uuid,
    idempotency_key: String,
    wait_for: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
