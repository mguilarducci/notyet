import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import notyet/wait
import notyet/web
import wisp/simulate

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn post(body_json: json.Json) {
  simulate.request(http.Post, "/wait")
  |> simulate.json_body(body_json)
  |> wait.create(web.Context)
}

fn read_field(response, field) {
  let assert Ok(value) =
    simulate.read_body(response)
    |> json.parse(decode.at([field], decode.string))
  value
}

pub fn valid_post_returns_201_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 minutes")),
        #("activity", json.string(v4)),
      ]),
    )
  assert response.status == 201
}

pub fn response_status_field_is_waiting_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 minutes")),
        #("activity", json.string(v4)),
      ]),
    )
  assert read_field(response, "status") == "waiting"
}

pub fn response_id_is_non_empty_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 minutes")),
        #("activity", json.string(v4)),
      ]),
    )
  assert read_field(response, "id") != ""
}

pub fn timestamps_are_utc_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 minutes")),
        #("activity", json.string(v4)),
      ]),
    )
  assert string.ends_with(read_field(response, "created_at"), "Z")
  assert string.ends_with(read_field(response, "for"), "Z")
}

pub fn for_is_now_plus_duration_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 minutes")),
        #("activity", json.string(v4)),
      ]),
    )
  let assert Ok(created_at) =
    timestamp.parse_rfc3339(read_field(response, "created_at"))
  let assert Ok(for_time) = timestamp.parse_rfc3339(read_field(response, "for"))
  // difference(left, right) is right - left, so this is for - created_at.
  assert timestamp.difference(created_at, for_time) == duration.seconds(300)
}

pub fn empty_for_returns_422_test() {
  let response =
    post(
      json.object([
        #("for", json.string("")),
        #("activity", json.string(v4)),
      ]),
    )
  assert response.status == 422
}

pub fn month_unit_returns_422_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 months")),
        #("activity", json.string(v4)),
      ]),
    )
  assert response.status == 422
}

pub fn valid_post_with_data_returns_201_test() {
  let body =
    json.object([
      #("for", json.string("5 minutes")),
      #("activity", json.string(v4)),
      #("data", json.object([#("abc", json.int(1))])),
    ])
  let response = post(body)
  assert response.status == 201
}

pub fn post_without_data_returns_201_test() {
  let response =
    post(
      json.object([
        #("for", json.string("5 minutes")),
        #("activity", json.string(v4)),
      ]),
    )
  assert response.status == 201
}

pub fn data_not_object_returns_422_test() {
  let body =
    json.object([
      #("for", json.string("5 minutes")),
      #("activity", json.string(v4)),
      #("data", json.array([1, 2], json.int)),
    ])
  let response = post(body)
  assert response.status == 422
}
