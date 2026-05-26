import gleam/result
import notyet/task/validate

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

// Same canonical UUID but with the version nibble set to 1 (a v1 UUID): a
// well-formed RFC4122 UUID that is not v4, so it must be rejected.
const v1 = "f47ac10b-58cc-1372-a567-0e02b2c3d479"

pub fn uuid_v4_accepts_v4_test() {
  assert validate.uuid_v4(v4) |> result.is_ok
}

pub fn uuid_v4_accepts_uppercase_v4_test() {
  assert validate.uuid_v4("F47AC10B-58CC-4372-A567-0E02B2C3D479")
    |> result.is_ok
}

pub fn uuid_v4_rejects_non_v4_test() {
  assert validate.uuid_v4(v1) |> result.is_error
}

pub fn uuid_v4_rejects_garbage_test() {
  assert validate.uuid_v4("not-a-uuid") |> result.is_error
}

pub fn uuid_v4_rejects_empty_test() {
  assert validate.uuid_v4("") |> result.is_error
}

pub fn url_http_accepts_http_test() {
  assert validate.url_http("http://example.com/cb")
    == Ok("http://example.com/cb")
}

pub fn url_http_accepts_https_test() {
  assert validate.url_http("https://example.com/cb")
    == Ok("https://example.com/cb")
}

pub fn url_http_rejects_missing_scheme_test() {
  assert validate.url_http("example.com") |> result.is_error
}

pub fn url_http_rejects_non_http_scheme_test() {
  assert validate.url_http("ftp://example.com") |> result.is_error
}

pub fn url_http_rejects_empty_host_test() {
  assert validate.url_http("http:///path") |> result.is_error
}

pub fn url_http_rejects_https_empty_host_test() {
  assert validate.url_http("https:///path") |> result.is_error
}

pub fn url_http_rejects_garbage_test() {
  assert validate.url_http("not a url") |> result.is_error
}

pub fn url_http_rejects_userinfo_test() {
  assert validate.url_http("http://user:pass@example.com/cb")
    |> result.is_error
}

pub fn url_http_rejects_userinfo_user_only_test() {
  assert validate.url_http("https://user@example.com") |> result.is_error
}
