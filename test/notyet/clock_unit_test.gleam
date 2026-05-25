import gleam/time/timestamp
import notyet/clock

// Round-trip: formatting then parsing must recover the exact instant. Mirrors
// the existing view_unit_test approach and is robust to lib formatting details.
pub fn rfc3339_round_trips_test() {
  let t = timestamp.from_unix_seconds(1_000_000)
  let assert Ok(parsed) = timestamp.parse_rfc3339(clock.rfc3339(t))
  assert parsed == t
}

pub fn rfc3339_round_trips_epoch_test() {
  let t = timestamp.from_unix_seconds(0)
  let assert Ok(parsed) = timestamp.parse_rfc3339(clock.rfc3339(t))
  assert parsed == t
}
