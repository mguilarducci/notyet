import gleam/dynamic/decode
import gleam/http
import gleam/json
import notyet/router
import notyet/task/sql
import test_helper
import wisp/simulate

fn dummy_ctx() {
  test_helper.writer_ctx(test_helper.dummy_connection(), 1, 200, 4)
}

const tgt = "{\"type\":\"webhook\",\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

const cfg = "{\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

fn post_body() -> String {
  "{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> "}"
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Put, "/tasks") |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown") |> router.handle_request(dummy_ctx())
  assert response.status == 404
}

pub fn get_task_returns_200_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [test_helper.v4],
      [test_helper.v4],
      ["5 minutes"],
      ["webhook"],
      [cfg],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4)
    |> router.handle_request(ctx)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert test_helper.json_field(body, "idempotency_key") == test_helper.v4
  let assert Ok(url) =
    json.parse(body, {
      use u <- decode.subfield(["target", "url"], decode.string)
      decode.success(u)
    })
  assert url == "https://example.com/cb"
}

pub fn get_task_missing_returns_404_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    simulate.request(http.Get, "/tasks/missing")
    |> router.handle_request(ctx)
  assert response.status == 404
}

pub fn get_task_wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Delete, "/tasks/whatever")
    |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn post_task_happy_path_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    test_helper.keyed_request(post_body(), test_helper.v4)
    |> router.handle_request(ctx)
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "pending"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn post_task_missing_target_422_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    test_helper.keyed_request("{\"wait_for\":\"5 minutes\"}", test_helper.v4)
    |> router.handle_request(ctx)
  assert response.status == 422
}

pub fn post_task_invalid_target_422_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let bad =
    "{\"type\":\"webhook\",\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}"
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"target\":" <> bad <> "}",
      test_helper.v4,
    )
    |> router.handle_request(ctx)
  assert response.status == 422
}
