import notyet/task/status

pub fn to_string_pending_test() {
  assert status.to_string(status.Pending) == "pending"
}

pub fn to_string_delivering_test() {
  assert status.to_string(status.Delivering) == "delivering"
}

pub fn to_string_delivered_test() {
  assert status.to_string(status.Delivered) == "delivered"
}

pub fn to_string_failed_test() {
  assert status.to_string(status.Failed) == "failed"
}

pub fn from_string_pending_test() {
  assert status.from_string("pending") == Ok(status.Pending)
}

pub fn from_string_delivering_test() {
  assert status.from_string("delivering") == Ok(status.Delivering)
}

pub fn from_string_delivered_test() {
  assert status.from_string("delivered") == Ok(status.Delivered)
}

pub fn from_string_failed_test() {
  assert status.from_string("failed") == Ok(status.Failed)
}

pub fn from_string_unknown_test() {
  assert status.from_string("bogus") == Error(Nil)
}

pub fn round_trip_pending_test() {
  assert status.from_string(status.to_string(status.Pending))
    == Ok(status.Pending)
}

pub fn round_trip_delivered_test() {
  assert status.from_string(status.to_string(status.Delivered))
    == Ok(status.Delivered)
}

pub fn round_trip_delivering_test() {
  assert status.from_string(status.to_string(status.Delivering))
    == Ok(status.Delivering)
}

pub fn round_trip_failed_test() {
  assert status.from_string(status.to_string(status.Failed))
    == Ok(status.Failed)
}
