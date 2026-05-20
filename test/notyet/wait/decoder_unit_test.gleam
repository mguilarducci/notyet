import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/time/duration
import notyet/wait

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300))
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
  assert req == wait.WaitRequest(duration: duration.seconds(300))
}
