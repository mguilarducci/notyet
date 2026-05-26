import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import notyet/task/target

pub fn method_to_string_test() {
  assert target.method_to_string(target.Get) == "GET"
  assert target.method_to_string(target.Post) == "POST"
  assert target.method_to_string(target.Put) == "PUT"
  assert target.method_to_string(target.Patch) == "PATCH"
  assert target.method_to_string(target.Delete) == "DELETE"
}

pub fn method_from_string_roundtrip_test() {
  assert target.method_from_string("GET") == Ok(target.Get)
  assert target.method_from_string("POST") == Ok(target.Post)
  assert target.method_from_string("PUT") == Ok(target.Put)
  assert target.method_from_string("PATCH") == Ok(target.Patch)
  assert target.method_from_string("DELETE") == Ok(target.Delete)
}

pub fn method_from_string_unknown_test() {
  assert result.is_error(target.method_from_string("TRACE"))
  assert result.is_error(target.method_from_string("post"))
}

fn decode_target(input: String) -> Result(target.Target, Nil) {
  case json.parse(input, target.decoder()) {
    Ok(t) -> Ok(t)
    Error(_) -> Error(Nil)
  }
}

pub fn decoder_accepts_full_webhook_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com/cb\",\"method\":\"POST\",\"headers\":{\"X-A\":\"b\"},\"body\":\"hi\"}"
  let assert Ok(target.Webhook(url, method, headers, body)) =
    decode_target(json)
  assert url == "https://x.com/cb"
  assert method == target.Post
  assert dict.get(headers, "X-A") == Ok("b")
  assert body == Some("hi")
}

pub fn decoder_defaults_headers_and_body_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"GET\"}"
  let assert Ok(target.Webhook(_, _, headers, body)) = decode_target(json)
  assert dict.size(headers) == 0
  assert body == None
}

pub fn decoder_rejects_bad_url_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"ftp://x.com\",\"method\":\"POST\",\"headers\":{}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_userinfo_url_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://u:p@x.com\",\"method\":\"POST\",\"headers\":{}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_bad_method_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"TRACE\",\"headers\":{}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_bad_header_name_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"POST\",\"headers\":{\"Bad Name\":\"v\"}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_unknown_type_test() {
  let json = "{\"type\":\"smoke-signal\",\"url\":\"https://x.com\"}"
  assert decode_target(json) == Error(Nil)
}
