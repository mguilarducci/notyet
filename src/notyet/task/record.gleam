import gleam/time/timestamp.{type Timestamp}
import notyet/task/target.{type Target}
import youid/uuid.{type Uuid}

/// A fully-formed task ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. `visible_at` is the
/// scheduler column; it equals `wait_until` at creation. `target` is the typed
/// delivery target (serialized to `target_kind` + `target_config` on insert).
pub type TaskRecord {
  TaskRecord(
    id: Uuid,
    idempotency_key: String,
    wait_for: String,
    target: Target,
    visible_at: Timestamp,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
