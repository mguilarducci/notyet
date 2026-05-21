import notyet/wait/status

pub fn to_string_received_test() {
  assert status.to_string(status.Received) == "received"
}

pub fn to_string_waiting_test() {
  assert status.to_string(status.Waiting) == "waiting"
}

pub fn from_string_received_test() {
  assert status.from_string("received") == Ok(status.Received)
}

pub fn from_string_waiting_test() {
  assert status.from_string("waiting") == Ok(status.Waiting)
}

pub fn from_string_unknown_test() {
  assert status.from_string("bogus") == Error(Nil)
}

pub fn round_trip_received_test() {
  assert status.from_string(status.to_string(status.Received))
    == Ok(status.Received)
}

pub fn round_trip_waiting_test() {
  assert status.from_string(status.to_string(status.Waiting))
    == Ok(status.Waiting)
}
