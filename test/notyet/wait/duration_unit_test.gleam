import gleam/result
import gleam/time/duration
import notyet/wait/duration as parser

pub fn seconds_singular_test() {
  assert parser.parse("1 second") == Ok(duration.seconds(1))
}

pub fn minutes_plural_test() {
  assert parser.parse("5 minutes") == Ok(duration.seconds(300))
}

pub fn hour_singular_test() {
  assert parser.parse("1 hour") == Ok(duration.seconds(3600))
}

pub fn days_plural_test() {
  assert parser.parse("2 days") == Ok(duration.seconds(172_800))
}

pub fn weeks_plural_test() {
  assert parser.parse("3 weeks") == Ok(duration.seconds(1_814_400))
}

pub fn seconds_plural_test() {
  assert parser.parse("5 seconds") == Ok(duration.seconds(5))
}

pub fn minute_singular_test() {
  assert parser.parse("1 minute") == Ok(duration.seconds(60))
}

pub fn hours_plural_test() {
  assert parser.parse("2 hours") == Ok(duration.seconds(7200))
}

pub fn day_singular_test() {
  assert parser.parse("1 day") == Ok(duration.seconds(86_400))
}

pub fn week_singular_test() {
  assert parser.parse("1 week") == Ok(duration.seconds(604_800))
}

pub fn plural_with_singular_unit_rejected_test() {
  assert parser.parse("2 minute") |> result.is_error
}

pub fn singular_with_plural_unit_rejected_test() {
  assert parser.parse("1 minutes") |> result.is_error
}

pub fn uppercase_unit_rejected_test() {
  assert parser.parse("1 Hour") |> result.is_error
}

pub fn leading_space_rejected_test() {
  assert parser.parse(" 2 days") |> result.is_error
}

pub fn trailing_space_rejected_test() {
  assert parser.parse("2 days ") |> result.is_error
}

pub fn double_space_rejected_test() {
  assert parser.parse("2  days") |> result.is_error
}

pub fn zero_rejected_test() {
  assert parser.parse("0 seconds") |> result.is_error
}

pub fn negative_rejected_test() {
  assert parser.parse("-3 days") |> result.is_error
}

pub fn month_unit_rejected_test() {
  assert parser.parse("5 months") |> result.is_error
}

pub fn year_unit_rejected_test() {
  assert parser.parse("1 year") |> result.is_error
}

pub fn garbage_rejected_test() {
  assert parser.parse("abc") |> result.is_error
}

pub fn number_only_rejected_test() {
  assert parser.parse("5") |> result.is_error
}

pub fn empty_rejected_test() {
  assert parser.parse("") |> result.is_error
}

// The number token is parsed with `int.parse` (Erlang `binary_to_integer`),
// which accepts a leading `+` and leading zeros. These are intentionally
// treated as valid: they still denote a positive integer and the resulting
// duration is correct. Documented here so the leniency is explicit.

pub fn leading_zero_accepted_test() {
  assert parser.parse("05 minutes") == Ok(duration.seconds(300))
}

pub fn leading_zero_singular_accepted_test() {
  assert parser.parse("01 second") == Ok(duration.seconds(1))
}

pub fn leading_plus_accepted_test() {
  assert parser.parse("+5 minutes") == Ok(duration.seconds(300))
}
