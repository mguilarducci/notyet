import gleam/json
import gleam/string
import gleam/time/timestamp
import notyet/wait
import notyet/wait/record
import notyet/wait/status
import youid/uuid

const id_string = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const activity_string = "1b4e28ba-2fa1-4d3b-a3f5-ccb4d2e3f000"

pub fn encode_response_shape_test() {
  let assert Ok(id) = uuid.from_string(id_string)
  let assert Ok(activity) = uuid.from_string(activity_string)
  let created_at = timestamp.from_unix_seconds(1000)
  let for_time = timestamp.from_unix_seconds(1300)
  let row =
    record.PersistedWait(
      id: id,
      activity: activity,
      status: status.Accepted,
      created_at: created_at,
      wait_until: for_time,
    )
  let output =
    wait.encode_response(row)
    |> json.to_string

  assert string.contains(output, "\"id\":\"" <> id_string <> "\"")
  assert string.contains(output, "\"activity\":\"" <> activity_string <> "\"")
  assert string.contains(output, "\"status\":\"accepted\"")
  assert string.contains(output, "\"created_at\":\"1970-01-01T00:16:40Z\"")
  assert string.contains(output, "\"for\":\"1970-01-01T00:21:40Z\"")
}
