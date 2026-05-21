import gleam/http
import notyet/router
import test_helper
import wisp/simulate

fn dummy_ctx() {
  // Router-only paths (405/404) never reach the writer, so an unstarted-pool
  // connection is safe.
  test_helper.writer_ctx(test_helper.dummy_connection(), 1, 200)
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
  let ctx = test_helper.writer_ctx(db, 1, 200)
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "router-k1",
    )
    |> router.handle_request(ctx)
  assert response.status == 201
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "accepted"
  assert test_helper.count_waits(db) == 1
}
