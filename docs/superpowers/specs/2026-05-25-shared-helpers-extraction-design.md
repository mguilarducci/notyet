# Shared Helpers Extraction — Design

**Date:** 2026-05-25
**Status:** Approved

## Problem

`src/notyet/task.gleam` holds two private helpers that are thin policy layers over
native primitives, and one formatting helper is duplicated verbatim across two
modules:

- `parse_uuid_v4` (`task.gleam:36`) — wraps `youid` (`uuid.from_string` + `uuid.version`);
  used **twice** inside `task.gleam` (write path `create`, read path `read`).
- `parse_http_url` (`task.gleam:49`) — wraps `gleam/uri.parse` with an http/https +
  non-empty-host policy; used **once** (destination decoder).
- `rfc3339` — `timestamp.to_rfc3339(t, calendar.utc_offset)`, **duplicated verbatim**
  in `view.gleam:35` and `batch.gleam:253`.

No native single-call equivalent exists for any of them: the standard library parses
(UUID, URI, timestamp) but does not encode the domain policy (v4-only, http/https URL,
UTC RFC3339). The duplicated `rfc3339` is the only proven reuse today; `uuid_v4`/`url_http`
have a single consumer each but are extracted now to establish a shared layer (the
future delivery worker will format timestamps via `rfc3339` but will not re-validate the
key or URL — those are write-path concerns).

## Goal

Establish a small shared layer, split by concern, with no behavior change:

- **Input validation** (parse untrusted string → validated value) → `src/notyet/validate.gleam`
- **Output formatting** (timestamp → RFC3339 string) → `src/notyet/clock.gleam`

This kills the `rfc3339` duplication and promotes the helpers from private (tested only
indirectly) to public (directly unit-testable).

Non-goals: no logic changes; no relocation of `config`'s private `string_var`/`int_var`/
`positive_var` (cohesive to config, no second consumer); no changes to `duration`/`status`.

## Design

### New module: `src/notyet/validate.gleam`

```gleam
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
```

Bodies are the current `parse_uuid_v4` / `parse_http_url` verbatim.

### New module: `src/notyet/clock.gleam`

```gleam
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// Format a timestamp as RFC3339 in UTC.
pub fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
```

### Call-site changes

**`task.gleam`**
- Delete `parse_uuid_v4` (lines 36-45) and `parse_http_url` (lines 49-59).
- Add `import notyet/validate`.
- Replace `parse_uuid_v4(...)` → `validate.uuid_v4(...)` (lines 88, 136).
- Replace `parse_http_url(s)` → `validate.url_http(s)` (line 63).
- Remove now-orphaned imports: `gleam/uri` (line 8), `gleam/option.{Some}` (line 5).
- Keep `youid/uuid` (still uses `uuid.v4`, `uuid.to_string`, `uuid.from_string`).

**`view.gleam`**
- Delete private `rfc3339` (lines 35-37).
- Add `import notyet/clock`.
- Replace the two `rfc3339(...)` calls → `clock.rfc3339(...)` (lines 29, 30).
- Remove orphaned `gleam/time/calendar` import. Keep `gleam/time/timestamp.{type Timestamp}`
  (the `Timestamp` type is still used in the `Task` record).

**`batch.gleam`**
- Delete private `rfc3339` (lines 253-255).
- Add `import notyet/clock`.
- Replace the six `rfc3339(...)` calls in `do_insert` → `clock.rfc3339(...)` (lines 247-249).
- Remove orphaned imports `gleam/time/calendar` (line 7) and `gleam/time/timestamp` (line 8)
  — both were used only by the moved `rfc3339`.

## Testing

Test-driven (repo convention: failing test first, then implementation/move).

New direct unit tests (mirroring `src/` layout under `test/notyet/`):

- **`validate_unit_test.gleam`**
  - `uuid_v4`: valid v4 → `Ok`; non-v4 (e.g. a v1 UUID) → `Error`; malformed string → `Error`;
    empty string → `Error`.
  - `url_http`: `http://…` → `Ok`; `https://…` → `Ok`; missing scheme → `Error`; non-http scheme
    (e.g. `ftp://…`) → `Error`; empty host → `Error`; malformed → `Error`.
- **`clock_unit_test.gleam`**
  - `rfc3339`: a known `Timestamp` formats to the expected UTC RFC3339 string.

Existing tests stay green (they cover these helpers indirectly): `decoder_unit_test`,
`handler_test`, `view_unit_test`, `batch_test`, `router_integration_test`.

## Coverage

Promoting the helpers from private to public with direct tests adds covered clauses; no
code is removed from measurement. The dual gate (lines ≥ 80%, clauses ≥ 90%) must hold or
improve. No coverage exclusions.

## Risk

Low. Pure mechanical move with no logic change; behavior is pinned by both the new direct
tests and the unchanged indirect tests. The only sharp edge is orphaned-import removal —
the compiler (`gleam build --warnings-as-errors` in CI) catches any miss.
