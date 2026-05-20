import gleam/dynamic/decode
import gleam/http
import gleam/json
import notyet/wait
import notyet/web
import wisp/simulate

fn post(body_json: json.Json) {
  simulate.request(http.Post, "/wait")
  |> simulate.json_body(body_json)
  |> wait.create(web.Context)
}

pub fn valid_post_returns_201_test() {
  let response = post(json.object([#("wait", json.string("foo"))]))
  assert response.status == 201
}

pub fn response_status_field_is_waiting_test() {
  let response = post(json.object([#("wait", json.string("foo"))]))
  let assert Ok(status) =
    simulate.read_body(response)
    |> json.parse(decode.at(["status"], decode.string))
  assert status == "waiting"
}

pub fn response_id_is_non_empty_test() {
  let response = post(json.object([#("wait", json.string("foo"))]))
  let assert Ok(id) =
    simulate.read_body(response)
    |> json.parse(decode.at(["id"], decode.string))
  assert id != ""
}

pub fn empty_wait_returns_422_test() {
  let response = post(json.object([#("wait", json.string(""))]))
  assert response.status == 422
}
