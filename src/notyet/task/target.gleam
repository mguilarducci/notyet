import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import notyet/task/validate

/// The delivery target — a closed sum type. Only `Webhook` exists this session;
/// future variants (QueuePublish, Email) are added as new arms (code change),
/// keeping every `case` exhaustive.
pub type Target {
  Webhook(
    url: String,
    method: Method,
    headers: Dict(String, String),
    body: Option(String),
  )
}

/// HTTP method for a webhook delivery. Closed set.
pub type Method {
  Get
  Post
  Put
  Patch
  Delete
}

pub fn method_to_string(method: Method) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Patch -> "PATCH"
    Delete -> "DELETE"
  }
}

pub fn method_from_string(value: String) -> Result(Method, Nil) {
  case value {
    "GET" -> Ok(Get)
    "POST" -> Ok(Post)
    "PUT" -> Ok(Put)
    "PATCH" -> Ok(Patch)
    "DELETE" -> Ok(Delete)
    _ -> Error(Nil)
  }
}

/// Boundary decoder: request JSON object → typed `Target`. Reads the `"type"`
/// discriminator, then runs the variant's decoder. This is the home of per-type
/// validation (url is a real http(s) URL, method is in-set, headers have valid
/// names and no CR/LF). A failure here becomes a 422.
pub fn decoder() -> decode.Decoder(Target) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "webhook" -> webhook_decoder()
    _ -> decode.failure(placeholder(), "known target type")
  }
}

fn webhook_decoder() -> decode.Decoder(Target) {
  use url <- decode.field("url", url_decoder())
  use method <- decode.field("method", method_decoder())
  use headers <- decode.optional_field("headers", dict.new(), headers_decoder())
  use body <- decode.optional_field(
    "body",
    option.None,
    decode.map(decode.string, option.Some),
  )
  decode.success(Webhook(url:, method:, headers:, body:))
}

fn url_decoder() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case validate.url_http(s) {
    Ok(u) -> decode.success(u)
    Error(_) -> decode.failure("", "http(s) url")
  }
}

fn method_decoder() -> decode.Decoder(Method) {
  use s <- decode.then(decode.string)
  case method_from_string(s) {
    Ok(m) -> decode.success(m)
    Error(_) -> decode.failure(Get, "http method")
  }
}

fn headers_decoder() -> decode.Decoder(Dict(String, String)) {
  use raw <- decode.then(decode.dict(decode.string, decode.string))
  case list.all(dict.to_list(raw), valid_header) {
    True -> decode.success(raw)
    False -> decode.failure(dict.new(), "valid headers")
  }
}

fn valid_header(pair: #(String, String)) -> Bool {
  result.is_ok(validate.header_name(pair.0))
  && result.is_ok(validate.header_value(pair.1))
}

/// Default value for the `decode.failure` of an unknown type; never surfaced
/// (a failure decoder discards it).
fn placeholder() -> Target {
  Webhook("", Get, dict.new(), option.None)
}
