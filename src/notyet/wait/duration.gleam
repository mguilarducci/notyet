import gleam/int
import gleam/string
import gleam/time/duration.{type Duration}

/// Parse a strict human-readable duration string of the form
/// `"{integer} {unit}"` into a `Duration`.
///
/// Rules: exactly one space, no leading/trailing/double spaces, lowercase
/// unit, integer > 0, and plural agreement (1 -> singular, otherwise plural).
/// Supported units: second, minute, hour, day, week. Anything else is an error.
pub fn parse(input: String) -> Result(Duration, Nil) {
  case string.split(input, " ") {
    [number, unit] ->
      case int.parse(number) {
        Ok(n) if n > 0 ->
          case seconds_per_unit(n, unit) {
            Ok(secs) -> Ok(duration.seconds(n * secs))
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn seconds_per_unit(n: Int, unit: String) -> Result(Int, Nil) {
  let plural = n > 1
  case unit, plural {
    "second", False -> Ok(1)
    "seconds", True -> Ok(1)
    "minute", False -> Ok(60)
    "minutes", True -> Ok(60)
    "hour", False -> Ok(3600)
    "hours", True -> Ok(3600)
    "day", False -> Ok(86_400)
    "days", True -> Ok(86_400)
    "week", False -> Ok(604_800)
    "weeks", True -> Ok(604_800)
    _, _ -> Error(Nil)
  }
}
