import gleam/dynamic/decode
import gleam/json
import gleam/result
import notyet/wait

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"wait\":\"foo\"}")
  assert req == wait.WaitRequest(wait: "foo")
}

pub fn empty_wait_rejected_test() {
  assert decode_json("{\"wait\":\"\"}") |> result.is_error
}

pub fn missing_wait_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"wait\":123}") |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) = decode_json("{\"wait\":\"foo\",\"extra\":\"x\"}")
  assert req.wait == "foo"
}
