import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// Format a timestamp as RFC3339 in UTC.
pub fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
