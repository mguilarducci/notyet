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

const tgt = "{\"type\":\"webhook\",\"url\":\"http://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

pub fn valid_payload_decodes_test() {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> "}")
  assert req.duration == duration.seconds(300)
  assert req.raw_wait_for == "5 minutes"
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"wait_for\":\"bogus\",\"target\":" <> tgt <> "}")
    |> result.is_error
}

pub fn empty_wait_for_rejected_test() {
  assert decode_json("{\"wait_for\":\"\",\"target\":" <> tgt <> "}")
    |> result.is_error
}

pub fn missing_wait_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"wait_for\":123,\"target\":" <> tgt <> "}")
    |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) =
    decode_json(
      "{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> ",\"extra\":\"x\"}",
    )
  assert req.raw_wait_for == "5 minutes"
}

pub fn raw_wait_for_preserved_verbatim_test() {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"+5 minutes\",\"target\":" <> tgt <> "}")
  assert req.raw_wait_for == "+5 minutes"
}

pub fn target_required_test() {
  assert decode_json("{\"wait_for\":\"5 minutes\"}") |> result.is_error
}

pub fn target_invalid_rejected_test() {
  let bad =
    "{\"type\":\"webhook\",\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}"
  assert decode_json("{\"wait_for\":\"5 minutes\",\"target\":" <> bad <> "}")
    |> result.is_error
}
