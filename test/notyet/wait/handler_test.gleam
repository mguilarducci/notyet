import gleam/http
import gleam/http/request
import notyet/wait
import test_helper
import wisp/simulate

fn ctx(db) {
  test_helper.writer_ctx(db, 1, 200)
}

pub fn create_persists_and_returns_201_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-201",
    )
    |> wait.create(ctx(db))
  assert response.status == 201
  assert test_helper.count_waits(db) == 1
}

pub fn create_with_data_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"1 hour\",\"activity\":\""
        <> test_helper.v4
        <> "\",\"data\":{\"k\":1}}",
      "k-data",
    )
    |> wait.create(ctx(db))
  assert response.status == 201
  assert test_helper.count_waits(db) == 1
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

pub fn response_contains_activity_and_accepted_status_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-shape",
    )
    |> wait.create(ctx(db))
  let body = simulate.read_body(response)
  assert test_helper.json_field(body, "activity") == test_helper.v4
  assert test_helper.json_field(body, "status") == "accepted"
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

pub fn retry_same_key_returns_same_id_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let first =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-1",
    )
    |> wait.create(context)
  // Retry with the SAME key but a DIFFERENT duration: the original row wins and
  // the new payload is ignored — same id AND same `for` as the first call.
  let second =
    test_helper.keyed_request(
      "{\"for\":\"1 hour\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-1",
    )
    |> wait.create(context)
  assert first.status == 201
  assert second.status == 201
  let first_body = simulate.read_body(first)
  let second_body = simulate.read_body(second)
  assert test_helper.json_field(first_body, "id")
    == test_helper.json_field(second_body, "id")
  assert test_helper.json_field(first_body, "for")
    == test_helper.json_field(second_body, "for")
  assert test_helper.count_waits(db) == 1
}
