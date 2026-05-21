import gleam/dynamic/decode
import gleam/list
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
    sql.insert_waits(db, [v4_a], [v4_a], [""], ["1 day"], [ts], [ts])
  assert count == 1
}

pub fn empty_data_becomes_null_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], [""], ["1 day"], [ts], [ts])
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
    sql.insert_waits(db, [], [], [], [], [], [])
  assert count == 0
  assert test_helper.count_waits(db) == 0
}
