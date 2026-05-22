import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import notyet/wait/json_value.{type JsonValue, JInt, JObject}
import notyet/wait/status
import notyet/wait/view
import test_helper
import youid/uuid

const id_str = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const activity_str = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

fn sample(data: option.Option(JsonValue)) -> view.Wait {
  let assert Ok(id) = uuid.from_string(id_str)
  let assert Ok(activity) = uuid.from_string(activity_str)
  view.Wait(
    id: id,
    activity: activity,
    idempotency_key: "k-1",
    status: status.Accepted,
    for_duration: "5 minutes",
    wait_until: timestamp.from_unix_seconds(1_000_000),
    created_at: timestamp.from_unix_seconds(900_000),
    data: data,
  )
}

pub fn encode_includes_core_fields_test() {
  let body = json.to_string(view.encode(sample(None)))
  assert test_helper.json_field(body, "id") == id_str
  assert test_helper.json_field(body, "activity") == activity_str
  assert test_helper.json_field(body, "idempotency_key") == "k-1"
  assert test_helper.json_field(body, "status") == "accepted"
  assert test_helper.json_field(body, "for") == "5 minutes"
}

pub fn encode_timestamps_are_rfc3339_utc_test() {
  let body = json.to_string(view.encode(sample(None)))
  let assert Ok(wu) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "wait_until"))
  assert wu == timestamp.from_unix_seconds(1_000_000)
  let assert Ok(ca) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "created_at"))
  assert ca == timestamp.from_unix_seconds(900_000)
}

pub fn encode_omits_data_when_none_test() {
  let body = json.to_string(view.encode(sample(None)))
  assert string.contains(body, "\"data\"") == False
}

pub fn encode_includes_data_object_when_present_test() {
  let data = JObject(dict.from_list([#("k", JInt(1))]))
  let body = json.to_string(view.encode(sample(Some(data))))
  let assert Ok(parsed) =
    json.parse(body, {
      use d <- decode.field("data", json_value.decoder())
      decode.success(d)
    })
  assert parsed == data
}

pub fn encode_status_waiting_test() {
  let waiting = view.Wait(..sample(None), status: status.Waiting)
  let body = json.to_string(view.encode(waiting))
  assert test_helper.json_field(body, "status") == "waiting"
}
