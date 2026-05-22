import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/time/duration
import gleeunit/should
import notyet/task

fn decode_json(
  input: String,
) -> Result(task.TaskRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, task.task_decoder())
}

const dest = "http://example.com/cb"

pub fn valid_payload_decodes_test() {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\"}")
  assert req.duration == duration.seconds(300)
  assert req.raw_wait_for == "5 minutes"
  assert req.destination == dest
}

pub fn invalid_duration_rejected_test() {
  assert decode_json(
    "{\"wait_for\":\"bogus\",\"destination\":\"" <> dest <> "\"}",
  )
  |> result.is_error
}

pub fn empty_wait_for_rejected_test() {
  assert decode_json("{\"wait_for\":\"\",\"destination\":\"" <> dest <> "\"}")
  |> result.is_error
}

pub fn missing_wait_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json(
    "{\"wait_for\":123,\"destination\":\"" <> dest <> "\"}",
  )
  |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) =
    decode_json(
      "{\"wait_for\":\"5 minutes\",\"destination\":\"" <> dest <> "\",\"extra\":\"x\"}",
    )
  assert req.duration == duration.seconds(300)
  assert req.raw_wait_for == "5 minutes"
}

pub fn raw_wait_for_preserved_verbatim_test() {
  let assert Ok(req) =
    decode_json(
      "{\"wait_for\":\"+5 minutes\",\"destination\":\"" <> dest <> "\"}",
    )
  assert req.raw_wait_for == "+5 minutes"
}

pub fn bad_wait_for_string_test() {
  assert decode_json(
    "{\"wait_for\":\"5 banana\",\"destination\":\"" <> dest <> "\"}",
  )
  |> result.is_error
}

pub fn destination_valid_http_test() {
  decode_json("{\"wait_for\":\"5 minutes\",\"destination\":\"http://example.com/cb\"}")
  |> result.is_ok
  |> should.be_true
}

pub fn destination_valid_https_test() {
  decode_json("{\"wait_for\":\"5 minutes\",\"destination\":\"https://example.com/cb\"}")
  |> result.is_ok
  |> should.be_true
}

pub fn destination_rejects_non_http_scheme_test() {
  decode_json("{\"wait_for\":\"5 minutes\",\"destination\":\"ftp://example.com\"}")
  |> result.is_error
  |> should.be_true
}

pub fn destination_rejects_missing_host_test() {
  decode_json("{\"wait_for\":\"5 minutes\",\"destination\":\"http:///path\"}")
  |> result.is_error
  |> should.be_true
}

pub fn destination_rejects_garbage_test() {
  decode_json("{\"wait_for\":\"5 minutes\",\"destination\":\"not a url\"}")
  |> result.is_error
  |> should.be_true
}

pub fn destination_required_test() {
  decode_json("{\"wait_for\":\"5 minutes\"}")
  |> result.is_error
  |> should.be_true
}
