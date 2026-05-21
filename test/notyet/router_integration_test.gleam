import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/otp/actor
import notyet/router
import notyet/wait/batch
import notyet/web
import test_helper
import wisp/simulate

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn dummy_ctx() -> web.Context {
  let assert Ok(actor.Started(_, subject)) =
    batch.start(
      test_helper.dummy_connection(),
      batch.Config(max_size: 1, interval_ms: 200),
    )
  web.Context(batch: subject, ack_timeout_ms: 5000)
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Put, "/wait") |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown") |> router.handle_request(dummy_ctx())
  assert response.status == 404
}

pub fn post_wait_happy_path_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 200))
  let ctx = web.Context(batch: subject, ack_timeout_ms: 5000)
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.string_body(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}",
    )
    |> request.set_header("content-type", "application/json")
    |> router.handle_request(ctx)
  assert response.status == 201
  let assert Ok(status) =
    json.parse(simulate.read_body(response), {
      use s <- decode.field("status", decode.string)
      decode.success(s)
    })
  assert status == "received"
  assert test_helper.count_waits(db) == 1
}
