import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/otp/actor
import notyet/wait
import notyet/wait/batch
import notyet/web
import test_helper
import wisp/simulate

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn ctx_with_writer(db) -> web.Context {
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 200))
  web.Context(batch: subject, ack_timeout_ms: 5000)
}

fn keyed_body(json_string: String, key: String) {
  simulate.request(http.Post, "/wait")
  |> simulate.string_body(json_string)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("idempotency-key", key)
}

fn json_field(body: String, field: String) -> String {
  let assert Ok(value) =
    json.parse(body, {
      use v <- decode.field(field, decode.string)
      decode.success(v)
    })
  value
}

pub fn create_persists_and_returns_201_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    keyed_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}", "k-201")
    |> wait.create(ctx)
  assert response.status == 201
  assert test_helper.count_waits(db) == 1
}

pub fn create_with_data_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    keyed_body(
      "{\"for\":\"1 hour\",\"activity\":\"" <> v4 <> "\",\"data\":{\"k\":1}}",
      "k-data",
    )
    |> wait.create(ctx)
  assert response.status == 201
  assert test_helper.count_waits(db) == 1
}

pub fn create_missing_activity_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    keyed_body("{\"for\":\"5 minutes\"}", "k-missing-activity")
    |> wait.create(ctx)
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn create_non_v4_activity_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let v7 = "018f6f6e-7000-7000-8000-000000000000"
  let response =
    keyed_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v7 <> "\"}", "k-v7")
    |> wait.create(ctx)
  assert response.status == 422
}

pub fn create_bad_for_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    keyed_body(
      "{\"for\":\"5 banana\",\"activity\":\"" <> v4 <> "\"}",
      "k-bad-for",
    )
    |> wait.create(ctx)
  assert response.status == 422
}

pub fn response_contains_activity_and_received_status_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    keyed_body(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}",
      "k-shape",
    )
    |> wait.create(ctx)
  let body_string = simulate.read_body(response)
  let assert Ok(activity) =
    json.parse(body_string, {
      use a <- decode.field("activity", decode.string)
      decode.success(a)
    })
  assert activity == v4
  let assert Ok(status) =
    json.parse(body_string, {
      use s <- decode.field("status", decode.string)
      decode.success(s)
    })
  assert status == "received"
}

pub fn missing_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.string_body(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}",
    )
    |> request.set_header("content-type", "application/json")
    |> wait.create(ctx)
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn retry_same_key_returns_same_id_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let first =
    keyed_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}", "k-1")
    |> wait.create(ctx)
  // Retry with the SAME key but a DIFFERENT duration: the original row wins and
  // the new payload is ignored — same id AND same `for` as the first call.
  let second =
    keyed_body("{\"for\":\"1 hour\",\"activity\":\"" <> v4 <> "\"}", "k-1")
    |> wait.create(ctx)
  assert first.status == 201
  assert second.status == 201
  let first_body = simulate.read_body(first)
  let second_body = simulate.read_body(second)
  assert json_field(first_body, "id") == json_field(second_body, "id")
  assert json_field(first_body, "for") == json_field(second_body, "for")
  assert test_helper.count_waits(db) == 1
}
