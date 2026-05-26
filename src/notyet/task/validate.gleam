import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import youid/uuid.{type Uuid}

/// Parse a string as a strict UUID v4. Non-UUID or non-v4 → Error.
pub fn uuid_v4(s: String) -> Result(Uuid, Nil) {
  case uuid.from_string(s) {
    Ok(u) ->
      case uuid.version(u) == uuid.V4 {
        True -> Ok(u)
        False -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

/// RFC 7230 token characters allowed in a header field-name.
const token_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"

/// Validate a header name as a non-empty RFC 7230 token. Rejects spaces, colons,
/// control chars, and CR/LF — so a name can never inject a new header line.
pub fn header_name(name: String) -> Result(String, Nil) {
  case name != "" && list.all(string.to_graphemes(name), is_token_char) {
    True -> Ok(name)
    False -> Error(Nil)
  }
}

fn is_token_char(c: String) -> Bool {
  string.contains(does: token_chars, contain: c)
}

/// The NUL byte (U+0000). PostgreSQL cannot store it in a JSONB value, so any
/// user-supplied string persisted into `target_config` must reject it at the
/// boundary — otherwise the async insert fails and the task is silently dropped
/// after a 202.
const nul = "\u{0000}"

/// Reject a string containing a NUL byte (see `nul`).
pub fn no_nul(s: String) -> Result(String, Nil) {
  case string.contains(s, nul) {
    True -> Error(Nil)
    False -> Ok(s)
  }
}

/// Validate a header value: no CR, LF, or NUL. CR/LF is the request-splitting /
/// header-injection vector; NUL cannot be stored in JSONB. Both are rejected.
pub fn header_value(value: String) -> Result(String, Nil) {
  case
    string.contains(value, "\r")
    || string.contains(value, "\n")
    || string.contains(value, nul)
  {
    True -> Error(Nil)
    False -> Ok(value)
  }
}

/// Validate a string as an http/https URL: parseable, scheme http|https,
/// non-empty host, and no userinfo (credentials). Returns the raw string (no
/// normalization). Userinfo is rejected so credentials never reach the stored
/// destination or the outbound request the delivery worker later makes.
pub fn url_http(s: String) -> Result(String, Nil) {
  case string.contains(s, nul) {
    True -> Error(Nil)
    False ->
      case uri.parse(s) {
        Error(_) -> Error(Nil)
        Ok(parsed) ->
          case parsed.userinfo {
            Some(_) -> Error(Nil)
            None ->
              case parsed.scheme, parsed.host {
                Some("http"), Some("") | Some("https"), Some("") -> Error(Nil)
                Some("http"), Some(_) | Some("https"), Some(_) -> Ok(s)
                _, _ -> Error(Nil)
              }
          }
      }
  }
}
