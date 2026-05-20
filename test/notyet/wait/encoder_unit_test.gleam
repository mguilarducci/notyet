import gleam/json
import notyet/wait

pub fn encode_response_shape_test() {
  let output = wait.encode_response("abc-123") |> json.to_string
  assert output == "{\"id\":\"abc-123\",\"status\":\"waiting\"}"
}
