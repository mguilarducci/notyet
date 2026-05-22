import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import notyet/wait
import notyet/wait/json_value.{JInt, JObject}
import youid/uuid

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) =
    decode_json("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
  let assert Ok(expected_uuid) = uuid.from_string(v4)
  assert req.duration == duration.seconds(300)
  assert req.activity == expected_uuid
  assert req.raw_for == "5 minutes"
  assert req.data == None
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"for\":\"bogus\",\"activity\":\"" <> v4 <> "\"}")
    |> result.is_error
}

pub fn empty_for_rejected_test() {
  assert decode_json("{\"for\":\"\",\"activity\":\"" <> v4 <> "\"}")
    |> result.is_error
}

pub fn missing_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"for\":123,\"activity\":\"" <> v4 <> "\"}")
    |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) =
    decode_json(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\",\"extra\":\"x\"}",
    )
  let assert Ok(expected_uuid) = uuid.from_string(v4)
  assert req.duration == duration.seconds(300)
  assert req.activity == expected_uuid
  assert req.raw_for == "5 minutes"
  assert req.data == None
}

pub fn data_object_decodes_to_some_test() {
  let assert Ok(req) =
    decode_json(
      "{\"for\":\"5 minutes\",\"activity\":\""
      <> v4
      <> "\",\"data\":{\"abc\":1}}",
    )
  assert req.data == Some(JObject(dict.from_list([#("abc", JInt(1))])))
}

pub fn data_absent_is_none_test() {
  let assert Ok(req) =
    decode_json("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
  assert req.data == None
}

pub fn data_array_rejected_test() {
  assert decode_json(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\",\"data\":[1,2]}",
    )
    |> result.is_error
}

pub fn data_string_rejected_test() {
  assert decode_json(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\",\"data\":\"x\"}",
    )
    |> result.is_error
}

pub fn data_null_rejected_test() {
  assert decode_json(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\",\"data\":null}",
    )
    |> result.is_error
}

pub fn valid_activity_v4_test() {
  let assert Ok(req) =
    decode_json("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
  assert uuid.to_string(req.activity) == v4
  assert req.raw_for == "5 minutes"
  assert req.data == None
}

pub fn activity_missing_test() {
  assert decode_json("{\"for\":\"5 minutes\"}") |> result.is_error
}

pub fn activity_not_a_string_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"activity\":123}")
    |> result.is_error
}

pub fn activity_not_a_uuid_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"activity\":\"nope\"}")
    |> result.is_error
}

pub fn activity_uuid_v1_rejected_test() {
  let v1 = "a8098c1a-f86e-11da-bd1a-00112444be1e"
  assert decode_json("{\"for\":\"5 minutes\",\"activity\":\"" <> v1 <> "\"}")
    |> result.is_error
}

pub fn activity_uuid_v7_rejected_test() {
  let v7 = "018f6f6e-7000-7000-8000-000000000000"
  assert decode_json("{\"for\":\"5 minutes\",\"activity\":\"" <> v7 <> "\"}")
    |> result.is_error
}

pub fn raw_for_preserved_verbatim_test() {
  let assert Ok(req) =
    decode_json("{\"for\":\"+5 minutes\",\"activity\":\"" <> v4 <> "\"}")
  assert req.raw_for == "+5 minutes"
}

pub fn bad_for_with_good_activity_test() {
  assert decode_json("{\"for\":\"5 banana\",\"activity\":\"" <> v4 <> "\"}")
    |> result.is_error
}

pub fn valid_with_data_object_test() {
  let assert Ok(req) =
    decode_json(
      "{\"for\":\"1 hour\",\"activity\":\"" <> v4 <> "\",\"data\":{\"k\":1}}",
    )
  assert req.data != None
}
