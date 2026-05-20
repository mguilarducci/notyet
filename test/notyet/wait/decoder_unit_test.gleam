import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import notyet/wait
import notyet/wait/json_value.{JInt, JObject}

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300), data: None)
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"for\":\"bogus\"}") |> result.is_error
}

pub fn empty_for_rejected_test() {
  assert decode_json("{\"for\":\"\"}") |> result.is_error
}

pub fn missing_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"for\":123}") |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\",\"extra\":\"x\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300), data: None)
}

pub fn data_object_decodes_to_some_test() {
  let assert Ok(req) =
    decode_json("{\"for\":\"5 minutes\",\"data\":{\"abc\":1}}")
  assert req
    == wait.WaitRequest(
      duration: duration.seconds(300),
      data: Some(JObject(dict.from_list([#("abc", JInt(1))]))),
    )
}

pub fn data_absent_is_none_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\"}")
  assert req.data == None
}

pub fn data_array_rejected_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"data\":[1,2]}")
    |> result.is_error
}

pub fn data_string_rejected_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"data\":\"x\"}")
    |> result.is_error
}

pub fn data_null_rejected_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"data\":null}")
    |> result.is_error
}
