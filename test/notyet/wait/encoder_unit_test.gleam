import gleam/json
import gleam/string
import gleam/time/timestamp
import notyet/wait

pub fn encode_response_shape_test() {
  let created_at = timestamp.from_unix_seconds(1000)
  let for_time = timestamp.from_unix_seconds(1300)
  let output =
    wait.encode_response("abc-123", created_at, for_time)
    |> json.to_string

  assert string.contains(output, "\"id\":\"abc-123\"")
  assert string.contains(output, "\"status\":\"waiting\"")
  assert string.contains(output, "\"created_at\":\"1970-01-01T00:16:40Z\"")
  assert string.contains(output, "\"for\":\"1970-01-01T00:21:40Z\"")
}
