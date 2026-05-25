import gleam/option.{Some}
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

/// Validate a string as an http/https URL: parseable, scheme http|https,
/// non-empty host. Returns the raw string (no normalization).
pub fn url_http(s: String) -> Result(String, Nil) {
  case uri.parse(s) {
    Error(_) -> Error(Nil)
    Ok(parsed) ->
      case parsed.scheme, parsed.host {
        Some("http"), Some("") | Some("https"), Some("") -> Error(Nil)
        Some("http"), Some(_) | Some("https"), Some(_) -> Ok(s)
        _, _ -> Error(Nil)
      }
  }
}
