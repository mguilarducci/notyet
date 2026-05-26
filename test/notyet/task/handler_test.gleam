import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import notyet/task
import notyet/task/sql
import test_helper
import wisp/simulate

fn ctx(db) {
  test_helper.writer_ctx(db, 1, 200, 4)
}

const tgt = "{\"type\":\"webhook\",\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

const cfg = "{\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

fn body(wait_for: String) -> String {
  "{\"wait_for\":\"" <> wait_for <> "\",\"target\":" <> tgt <> "}"
}

pub fn create_accepts_and_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 minutes"), test_helper.v4)
    |> task.create(ctx(db))
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "pending"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_bad_wait_for_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 banana"), test_helper.v4)
    |> task.create(ctx(db))
  assert response.status == 422
}

pub fn create_bad_target_422_test() {
  use db <- test_helper.with_db
  let bad =
    "{\"type\":\"webhook\",\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}"
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"target\":" <> bad <> "}",
      test_helper.v4,
    )
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn missing_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Post, "/tasks")
    |> simulate.string_body(body("5 minutes"))
    |> request.set_header("content-type", "application/json")
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn empty_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 minutes"), "")
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn non_v4_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 minutes"), "not-a-uuid")
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
      ["webhook"],
      [cfg],
      ["2026-05-20T12:00:00Z"],
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
  let resp_body = simulate.read_body(response)
  assert test_helper.json_field(resp_body, "idempotency_key") == test_helper.v4
  assert test_helper.json_field(resp_body, "status") == "pending"
  assert test_helper.json_field(resp_body, "wait_for") == "5 minutes"
  let assert Ok(url) =
    json.parse(resp_body, {
      use u <- decode.subfield(["target", "url"], decode.string)
      decode.success(u)
    })
  assert url == "https://example.com/cb"
}

pub fn read_missing_key_returns_404_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4_b)
    |> task.read(ctx(db), test_helper.v4_b)
  assert response.status == 404
}

pub fn read_non_v4_key_returns_404_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Get, "/tasks/not-a-uuid")
    |> task.read(ctx(db), "not-a-uuid")
  assert response.status == 404
}

pub fn uppercase_key_canonicalized_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let upper = "F47AC10B-58CC-4372-A567-0E02B2C3D479"
  let created =
    test_helper.keyed_request(body("5 minutes"), upper)
    |> task.create(context)
  assert created.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
  let got =
    simulate.request(http.Get, "/tasks/" <> upper)
    |> task.read(context, upper)
  assert got.status == 200
  assert test_helper.json_field(simulate.read_body(got), "idempotency_key")
    == test_helper.v4
}

pub fn retry_same_key_persists_once_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let first =
    test_helper.keyed_request(body("5 minutes"), test_helper.v4)
    |> task.create(context)
  let second =
    test_helper.keyed_request(body("1 hour"), test_helper.v4)
    |> task.create(context)
  assert first.status == 202
  assert second.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn read_query_error_returns_500_test() {
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(test_helper.broken_pool()), test_helper.v4)
  assert response.status == 500
}

pub fn read_wrong_method_returns_405_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Post, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(db), test_helper.v4)
  assert response.status == 405
}
