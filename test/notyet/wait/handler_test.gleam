import gleam/http
import gleam/http/request
import notyet/wait
import test_helper
import wisp/simulate

fn ctx(db) {
  test_helper.writer_ctx(db, 1, 200, 4)
}

pub fn create_accepts_and_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-202",
    )
    |> wait.create(ctx(db))
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "accepted"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_with_data_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"1 hour\",\"activity\":\""
        <> test_helper.v4
        <> "\",\"data\":{\"k\":1}}",
      "k-data",
    )
    |> wait.create(ctx(db))
  assert response.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_missing_activity_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request("{\"for\":\"5 minutes\"}", "k-missing-activity")
    |> wait.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn create_non_v4_activity_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v7 <> "\"}",
      "k-v7",
    )
    |> wait.create(ctx(db))
  assert response.status == 422
}

pub fn create_bad_for_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 banana\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-bad-for",
    )
    |> wait.create(ctx(db))
  assert response.status == 422
}

pub fn missing_idempotency_key_422_test() {
  use db <- test_helper.with_db
  // No Idempotency-Key header -> 422 before the body is even decoded.
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.string_body(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
    )
    |> request.set_header("content-type", "application/json")
    |> wait.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn empty_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "",
    )
    |> wait.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn retry_same_key_persists_once_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let first =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-1",
    )
    |> wait.create(context)
  // Retry with the SAME key but a DIFFERENT duration: dedup -> exactly one row.
  let second =
    test_helper.keyed_request(
      "{\"for\":\"1 hour\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-1",
    )
    |> wait.create(context)
  assert first.status == 202
  assert second.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}
