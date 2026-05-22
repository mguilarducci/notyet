import gleam/http
import gleam/http/request
import notyet/task
import notyet/task/sql
import test_helper
import wisp/simulate

fn ctx(db) {
  test_helper.writer_ctx(db, 1, 200, 4)
}

const dest = "https://example.com/cb"

pub fn create_accepts_and_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\"}",
      test_helper.v4,
    )
    |> task.create(ctx(db))
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "accepted"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_bad_wait_for_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 banana\",\"destination\":\"" <> dest <> "\"}",
      test_helper.v4,
    )
    |> task.create(ctx(db))
  assert response.status == 422
}

pub fn create_bad_destination_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"ftp://x\"}",
      test_helper.v4,
    )
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn missing_idempotency_key_422_test() {
  use db <- test_helper.with_db
  // No Idempotency-Key header -> 422 before the body is even decoded.
  let response =
    simulate.request(http.Post, "/tasks")
    |> simulate.string_body(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\"}",
    )
    |> request.set_header("content-type", "application/json")
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn empty_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\"}",
      "",
    )
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn non_v4_idempotency_key_422_test() {
  use db <- test_helper.with_db
  // A non-UUID-v4 key is rejected before the body is decoded.
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\"}",
      "not-a-uuid",
    )
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

fn seed(db, key) {
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [test_helper.v4],
      [key],
      ["5 minutes"],
      [dest],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  Nil
}

pub fn read_returns_200_with_resource_test() {
  use db <- test_helper.with_db
  seed(db, test_helper.v4)
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(db), test_helper.v4)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert test_helper.json_field(body, "idempotency_key") == test_helper.v4
  assert test_helper.json_field(body, "status") == "accepted"
  assert test_helper.json_field(body, "wait_for") == "5 minutes"
  assert test_helper.json_field(body, "destination") == dest
}

pub fn read_missing_key_returns_404_test() {
  use db <- test_helper.with_db
  // A valid v4 key with no stored row: the DB query returns empty -> 404.
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4_b)
    |> task.read(ctx(db), test_helper.v4_b)
  assert response.status == 404
}

pub fn read_non_v4_key_returns_404_test() {
  use db <- test_helper.with_db
  // A non-v4 key cannot identify any stored task (keys are v4) -> 404, no query.
  let response =
    simulate.request(http.Get, "/tasks/not-a-uuid")
    |> task.read(ctx(db), "not-a-uuid")
  assert response.status == 404
}

pub fn retry_same_key_persists_once_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let first =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\"}",
      test_helper.v4,
    )
    |> task.create(context)
  // Retry with the SAME key but a DIFFERENT duration: dedup -> exactly one row.
  let second =
    test_helper.keyed_request(
      "{\"wait_for\":\"1 hour\",\"destination\":\"" <> dest <> "\"}",
      test_helper.v4,
    )
    |> task.create(context)
  assert first.status == 202
  assert second.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn read_wrong_method_returns_405_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Post, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(db), test_helper.v4)
  assert response.status == 405
}
