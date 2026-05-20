import gleam/dynamic/decode

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
