/// Lifecycle state of a task. `Accepted` is the initial state set at creation
/// (the `202 Accepted` ack and the persisted row share this name). `Waiting` is
/// a later state; nothing transitions to it yet (out of scope).
pub type Status {
  Accepted
  Waiting
}

pub fn to_string(status: Status) -> String {
  case status {
    Accepted -> "accepted"
    Waiting -> "waiting"
  }
}

pub fn from_string(value: String) -> Result(Status, Nil) {
  case value {
    "accepted" -> Ok(Accepted)
    "waiting" -> Ok(Waiting)
    _ -> Error(Nil)
  }
}
