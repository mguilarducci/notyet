import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/time/duration
import notyet/task

fn decode_json(
  input: String,
) -> Result(task.TaskRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, task.task_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"wait_for\":\"5 minutes\"}")
  assert req.duration == duration.seconds(300)
  assert req.raw_wait_for == "5 minutes"
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"wait_for\":\"bogus\"}") |> result.is_error
}

pub fn empty_wait_for_rejected_test() {
  assert decode_json("{\"wait_for\":\"\"}") |> result.is_error
}

pub fn missing_wait_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"wait_for\":123}") |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"5 minutes\",\"extra\":\"x\"}")
  assert req.duration == duration.seconds(300)
  assert req.raw_wait_for == "5 minutes"
}

pub fn raw_wait_for_preserved_verbatim_test() {
  let assert Ok(req) = decode_json("{\"wait_for\":\"+5 minutes\"}")
  assert req.raw_wait_for == "+5 minutes"
}

pub fn bad_wait_for_string_test() {
  assert decode_json("{\"wait_for\":\"5 banana\"}") |> result.is_error
}
