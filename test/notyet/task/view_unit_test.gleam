import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/time/timestamp
import notyet/task/status
import notyet/task/target
import notyet/task/view
import test_helper
import youid/uuid

const id_str = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn sample() -> view.Task {
  let assert Ok(id) = uuid.from_string(id_str)
  view.Task(
    id: id,
    idempotency_key: "k-1",
    status: status.Pending,
    wait_for: "5 minutes",
    wait_until: timestamp.from_unix_seconds(1_000_000),
    created_at: timestamp.from_unix_seconds(900_000),
    target: target.Webhook(
      url: "https://example.com/cb",
      method: target.Post,
      headers: dict.new(),
      body: None,
    ),
  )
}

pub fn encode_includes_core_fields_test() {
  let body = json.to_string(view.encode(sample()))
  assert test_helper.json_field(body, "id") == id_str
  assert test_helper.json_field(body, "idempotency_key") == "k-1"
  assert test_helper.json_field(body, "status") == "pending"
  assert test_helper.json_field(body, "wait_for") == "5 minutes"
}

pub fn encode_nests_target_test() {
  let body = json.to_string(view.encode(sample()))
  let assert Ok(#(type_, url)) =
    json.parse(body, {
      use t <- decode.subfield(["target", "type"], decode.string)
      use u <- decode.subfield(["target", "url"], decode.string)
      decode.success(#(t, u))
    })
  assert type_ == "webhook"
  assert url == "https://example.com/cb"
}

pub fn encode_omits_destination_key_test() {
  let body = json.to_string(view.encode(sample()))
  assert test_helper.json_field_missing(body, "destination")
}

pub fn encode_timestamps_are_rfc3339_utc_test() {
  let body = json.to_string(view.encode(sample()))
  let assert Ok(wu) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "wait_until"))
  assert wu == timestamp.from_unix_seconds(1_000_000)
  let assert Ok(ca) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "created_at"))
  assert ca == timestamp.from_unix_seconds(900_000)
}

pub fn encode_status_delivered_test() {
  let delivered = view.Task(..sample(), status: status.Delivered)
  let body = json.to_string(view.encode(delivered))
  assert test_helper.json_field(body, "status") == "delivered"
}

pub fn encode_omits_visible_at_test() {
  let body = json.to_string(view.encode(sample()))
  assert test_helper.json_field_missing(body, "visible_at")
}
