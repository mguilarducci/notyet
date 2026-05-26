import gleam/option.{None, Some}
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
/// non-empty host, and no userinfo (credentials). Returns the raw string (no
/// normalization). Userinfo is rejected so credentials never reach the stored
/// destination or the outbound request the delivery worker later makes.
pub fn url_http(s: String) -> Result(String, Nil) {
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
