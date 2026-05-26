import gleam/dict
import gleam/option.{None}
import gleam/time/timestamp
import notyet/task/sql
import notyet/task/target
import pog
import test_helper

const v4_a = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

const ts = "2026-05-20T12:00:00Z"

const kind = "webhook"

const cfg = "{\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

pub fn insert_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(
      db,
      [v4_a, v4_b],
      ["k-a", "k-b"],
      ["5 minutes", "1 hour"],
      [kind, kind],
      [cfg, cfg],
      [ts, ts],
      [ts, ts],
      [ts, ts],
    )
  assert count == 2
  assert test_helper.count_tasks(db) == 2
}

pub fn insert_single_row_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(db, [v4_a], ["k-a"], ["1 day"], [kind], [cfg], [ts], [ts], [
      ts,
    ])
  assert count == 1
}

pub fn empty_list_no_op_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(db, [], [], [], [], [], [], [], [])
  assert count == 0
  assert test_helper.count_tasks(db) == 0
}

pub fn get_by_key_returns_inserted_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a],
      ["look-me-up"],
      ["5 minutes"],
      [kind],
      [cfg],
      [ts],
      [ts],
      [ts],
    )
  let assert Ok(pog.Returned(count, [row])) =
    sql.get_task_by_idempotency_key(db, "look-me-up")
  assert count == 1
  assert row.id == v4_a
  assert row.idempotency_key == "look-me-up"
  assert row.status == "pending"
  assert row.wait_for == "5 minutes"
  assert row.target_kind == "webhook"
  let assert Ok(decoded) =
    target.from_storage(row.target_kind, row.target_config)
  assert decoded
    == target.Webhook(
      url: "https://example.com/cb",
      method: target.Post,
      headers: dict.new(),
      body: None,
    )
  let assert Ok(expected) = timestamp.parse_rfc3339(ts)
  let assert Ok(returned_wait_until) = timestamp.parse_rfc3339(row.wait_until)
  assert returned_wait_until == expected
  let assert Ok(returned_created_at) = timestamp.parse_rfc3339(row.created_at)
  assert returned_created_at == expected
}

pub fn get_by_key_missing_returns_empty_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, rows)) =
    sql.get_task_by_idempotency_key(db, "nope")
  assert count == 0
  assert rows == []
}

pub fn same_key_dedups_to_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a],
      ["key-1"],
      ["5 minutes"],
      [kind],
      [cfg],
      [ts],
      [
        ts,
      ],
      [ts],
    )
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_b],
      ["key-1"],
      ["1 hour"],
      [kind],
      [cfg],
      [ts],
      [
        ts,
      ],
      [ts],
    )
  assert test_helper.count_tasks(db) == 1
}

pub fn intra_batch_same_key_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a, v4_b],
      ["same", "same"],
      ["1 day", "1 day"],
      [kind, kind],
      [cfg, cfg],
      [ts, ts],
      [ts, ts],
      [ts, ts],
    )
  assert test_helper.count_tasks(db) == 1
}

pub fn distinct_keys_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a],
      ["key-1"],
      ["1 day"],
      [kind],
      [cfg],
      [ts],
      [ts],
      [
        ts,
      ],
    )
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_b],
      ["key-2"],
      ["1 day"],
      [kind],
      [cfg],
      [ts],
      [ts],
      [
        ts,
      ],
    )
  assert test_helper.count_tasks(db) == 2
}
