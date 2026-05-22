import notyet/task/status

pub fn to_string_accepted_test() {
  assert status.to_string(status.Accepted) == "accepted"
}

pub fn to_string_waiting_test() {
  assert status.to_string(status.Waiting) == "waiting"
}

pub fn from_string_accepted_test() {
  assert status.from_string("accepted") == Ok(status.Accepted)
}

pub fn from_string_waiting_test() {
  assert status.from_string("waiting") == Ok(status.Waiting)
}

pub fn from_string_unknown_test() {
  assert status.from_string("bogus") == Error(Nil)
}

pub fn round_trip_accepted_test() {
  assert status.from_string(status.to_string(status.Accepted))
    == Ok(status.Accepted)
}

pub fn round_trip_waiting_test() {
  assert status.from_string(status.to_string(status.Waiting))
    == Ok(status.Waiting)
}
