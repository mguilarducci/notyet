import gleam/dynamic/decode
import gleam/list
import gleam/time/calendar
import gleam/time/timestamp
import notyet/wait/sql
import pog
import test_helper

const v4_a = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

const ts = "2026-05-20T12:00:00Z"

pub fn insert_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, rows)) =
    sql.insert_waits(
      db,
      [v4_a, v4_b],
      [v4_a, v4_b],
      ["k-a", "k-b"],
      ["{\"k\":1}", ""],
      ["5 minutes", "1 hour"],
      [ts, ts],
      [ts, ts],
    )
  assert count == 2
  assert list.length(rows) == 2
  assert test_helper.count_waits(db) == 2
}

pub fn insert_single_row_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(db, [v4_a], [v4_a], ["k-a"], [""], ["1 day"], [ts], [ts])
  assert count == 1
}

pub fn empty_data_becomes_null_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["k-a"], [""], ["1 day"], [ts], [ts])
  let assert Ok(pog.Returned(_, [is_null])) =
    "SELECT (data IS NULL) FROM waits"
    |> pog.query
    |> pog.returning({
      use b <- decode.field(0, decode.bool)
      decode.success(b)
    })
    |> pog.execute(db)
  assert is_null == True
}

pub fn empty_list_no_op_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(db, [], [], [], [], [], [], [])
  assert count == 0
  assert test_helper.count_waits(db) == 0
}

pub fn same_key_dedups_to_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(_, [row1])) =
    sql.insert_waits(db, [v4_a], [v4_a], ["key-1"], [""], ["5 minutes"], [ts], [
      ts,
    ])
  let assert Ok(pog.Returned(_, [row2])) =
    sql.insert_waits(db, [v4_b], [v4_b], ["key-1"], [""], ["1 hour"], [ts], [ts])
  assert row1.id == row2.id
  assert test_helper.count_waits(db) == 1
}

pub fn distinct_keys_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["key-1"], [""], ["1 day"], [ts], [ts])
  let assert Ok(_) =
    sql.insert_waits(db, [v4_b], [v4_b], ["key-2"], [""], ["1 day"], [ts], [ts])
  assert test_helper.count_waits(db) == 2
}

// The RETURNING timestamps use `AT TIME ZONE 'UTC'` so the DB->Gleam round-trip
// is independent of the session timezone. Assert the returned instants equal
// what was inserted (RFC3339 UTC, `Z`).
pub fn timestamps_round_trip_utc_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(_, [row])) =
    sql.insert_waits(db, [v4_a], [v4_a], ["rt-key"], [""], ["5 minutes"], [ts], [
      ts,
    ])
  assert timestamp.to_rfc3339(row.created_at, calendar.utc_offset) == ts
  assert timestamp.to_rfc3339(row.wait_until, calendar.utc_offset) == ts
}
