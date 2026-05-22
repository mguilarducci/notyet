/// Lifecycle state of a task. `Pending` is the initial state set at creation
/// (the row's `visible_at` is still in the future). The remaining states are
/// produced by the delivery worker (later phase): `Delivering` while the
/// `destination` call is in flight, then the terminal `Delivered` (HTTP 2xx) or
/// `Failed`. Nothing transitions out of `Pending` yet (out of scope).
pub type Status {
  Pending
  Delivering
  Delivered
  Failed
}

pub fn to_string(status: Status) -> String {
  case status {
    Pending -> "pending"
    Delivering -> "delivering"
    Delivered -> "delivered"
    Failed -> "failed"
  }
}

pub fn from_string(value: String) -> Result(Status, Nil) {
  case value {
    "pending" -> Ok(Pending)
    "delivering" -> Ok(Delivering)
    "delivered" -> Ok(Delivered)
    "failed" -> Ok(Failed)
    _ -> Error(Nil)
  }
}
