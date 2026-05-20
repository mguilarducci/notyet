import gleam/http
import gleam/json
import notyet/router
import notyet/web
import wisp/simulate

pub fn post_wait_dispatches_to_handler_test() {
  let body = json.object([#("for", json.string("5 minutes"))])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 201
}

pub fn invalid_duration_returns_422_test() {
  let body = json.object([#("for", json.string("nope"))])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 422
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Get, "/wait")
    |> router.handle_request(web.Context)

  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown")
    |> router.handle_request(web.Context)

  assert response.status == 404
}

pub fn post_wait_with_data_dispatches_to_handler_test() {
  let body =
    json.object([
      #("for", json.string("5 minutes")),
      #("data", json.object([#("abc", json.int(1))])),
    ])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 201
}
