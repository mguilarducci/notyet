import gleam/dynamic/decode
import notyet/wait/sql
import pog
import test_helper

const v4_a = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

const ts = "2026-05-20T12:00:00Z"

pub fn insert_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
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

pub fn get_by_key_returns_inserted_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(
      db,
      [v4_a],
      [v4_b],
      ["look-me-up"],
      ["{\"k\":1}"],
      ["5 minutes"],
      [ts],
      [ts],
    )
  let assert Ok(pog.Returned(count, [row])) =
    sql.get_wait_by_idempotency_key(db, "look-me-up")
  assert count == 1
  assert row.id == v4_a
  assert row.activity == v4_b
  assert row.idempotency_key == "look-me-up"
  assert row.status == "accepted"
  assert row.for_duration == "5 minutes"
  // Postgres re-serializes jsonb with a space after the colon: {"k":1} -> {"k": 1}.
  assert row.data == "{\"k\": 1}"
}

pub fn get_by_key_missing_returns_empty_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, rows)) =
    sql.get_wait_by_idempotency_key(db, "nope")
  assert count == 0
  assert rows == []
}

pub fn get_by_key_null_data_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["no-data"], [""], ["1 day"], [ts], [ts])
  let assert Ok(pog.Returned(_, [row])) =
    sql.get_wait_by_idempotency_key(db, "no-data")
  // COALESCE(data::text, '') maps SQL NULL to empty string.
  assert row.data == ""
}

// DO NOTHING: a repeated key across calls inserts no second row, no error.
pub fn same_key_dedups_to_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["key-1"], [""], ["5 minutes"], [ts], [
      ts,
    ])
  let assert Ok(_) =
    sql.insert_waits(db, [v4_b], [v4_b], ["key-1"], [""], ["1 hour"], [ts], [ts])
  assert test_helper.count_waits(db) == 1
}

// DO NOTHING tolerates an intra-statement duplicate key (unlike DO UPDATE,
// which raises "cannot affect row a second time").
pub fn intra_batch_same_key_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(
      db,
      [v4_a, v4_b],
      [v4_a, v4_b],
      ["same", "same"],
      ["", ""],
      ["1 day", "1 day"],
      [ts, ts],
      [ts, ts],
    )
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
