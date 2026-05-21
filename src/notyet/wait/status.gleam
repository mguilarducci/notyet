/// Lifecycle state of a wait. `Received` is the initial state set at creation.
/// `Waiting` is a later state; nothing transitions to it yet (out of scope).
pub type Status {
  Received
  Waiting
}

pub fn to_string(status: Status) -> String {
  case status {
    Received -> "received"
    Waiting -> "waiting"
  }
}

pub fn from_string(value: String) -> Result(Status, Nil) {
  case value {
    "received" -> Ok(Received)
    "waiting" -> Ok(Waiting)
    _ -> Error(Nil)
  }
}
