import gleam/dynamic/decode
import gleam/json

pub type WaitRequest {
  WaitRequest(wait: String)
}

fn non_empty_string() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case s {
    "" -> decode.failure("", "non-empty string")
    _ -> decode.success(s)
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use wait <- decode.field("wait", non_empty_string())
  decode.success(WaitRequest(wait:))
}

pub fn encode_response(id: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("status", json.string("waiting")),
  ])
}
