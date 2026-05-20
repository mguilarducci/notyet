import gleam/http
import gleam/json
import notyet/router
import notyet/web
import wisp/simulate

pub fn post_wait_dispatches_to_handler_test() {
  let body = json.object([#("wait", json.string("foo"))])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 201
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
