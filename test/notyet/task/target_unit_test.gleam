import gleam/dict
import gleam/dynamic/decode
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

fn sample() -> target.Target {
  target.Webhook(
    url: "https://x.com/cb",
    method: target.Post,
    headers: dict.from_list([#("X-A", "b")]),
    body: Some("hi"),
  )
}

fn field(body: String, key: String) -> String {
  let assert Ok(v) =
    json.parse(body, {
      use s <- decode.field(key, decode.string)
      decode.success(s)
    })
  v
}

pub fn encode_includes_type_and_fields_test() {
  let body = json.to_string(target.encode(sample()))
  assert field(body, "type") == "webhook"
  assert field(body, "url") == "https://x.com/cb"
  assert field(body, "method") == "POST"
}

pub fn encode_omits_body_when_none_test() {
  let no_body = target.Webhook(..sample(), body: None)
  let body = json.to_string(target.encode(no_body))
  let parsed =
    json.parse(body, {
      use b <- decode.optional_field(
        "body",
        None,
        decode.map(decode.string, Some),
      )
      decode.success(b)
    })
  assert parsed == Ok(None)
}

pub fn to_storage_kind_and_config_test() {
  let #(kind, config) = target.to_storage(sample())
  assert kind == "webhook"
  let has_type =
    json.parse(config, {
      use t <- decode.optional_field(
        "type",
        None,
        decode.map(decode.string, Some),
      )
      decode.success(t)
    })
  assert has_type == Ok(None)
}

pub fn storage_roundtrip_test() {
  let #(kind, config) = target.to_storage(sample())
  assert target.from_storage(kind, config) == Ok(sample())
}

pub fn from_storage_unknown_kind_test() {
  assert target.from_storage("email", "{}") == Error(Nil)
}

pub fn decoder_rejects_nul_in_body_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"POST\",\"headers\":{},\"body\":\"a\\u0000b\"}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_nul_in_header_value_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"POST\",\"headers\":{\"X-A\":\"a\\u0000b\"}}"
  assert decode_target(json) == Error(Nil)
}

// from_storage is structural: a config the write boundary would reject (here an
// ftp url) still decodes on read, so a CHECK-satisfying row never panics
// row_to_task's `let assert`.
pub fn from_storage_accepts_business_invalid_url_test() {
  let assert Ok(target.Webhook(url, _, _, _)) =
    target.from_storage(
      "webhook",
      "{\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}",
    )
  assert url == "ftp://x"
}
