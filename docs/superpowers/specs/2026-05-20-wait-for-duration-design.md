# Design: POST /wait with human-readable duration

**Date:** 2026-05-20
**Status:** Approved

## Goal

Evolve `POST /wait` so the request carries a human-readable duration and the
response reports when the wait was created and when it ends.

Changes from the [original design](2026-05-20-wait-endpoint-design.md):

1. Rename the request field `wait` → `for`.
2. `for` is a strict human-readable duration string (`"{number} {unit}"`),
   parsed into a real duration with `gleam_time`.
3. The response gains `created_at` and `for`, both RFC 3339 UTC timestamps,
   where `created_at = now` and `for = now + duration`, computed from a single
   captured `now`.

The submitted duration still drives no real sleeping/scheduling — it only
computes the response timestamps.

## API Contract

### Request

```
POST /wait
Content-Type: application/json

{ "for": "<duration string>" }
```

### Success Response

```
201 Created
Content-Type: application/json

{
  "id": "<uuid v4>",
  "status": "waiting",
  "created_at": "2026-05-20T22:30:00Z",
  "for": "2026-05-20T22:35:00Z"
}
```

- `id` — randomly generated UUID v4, serialized as a string.
- `status` — always the literal `"waiting"`.
- `created_at` — the moment the request was handled (`now`), RFC 3339 UTC.
- `for` — `now + duration`, RFC 3339 UTC.

Both timestamps are produced from a single `timestamp.system_time()` capture, so
`for - created_at` exactly equals the requested duration. They are formatted
with `timestamp.to_rfc3339(_, calendar.utc_offset)`, which yields a trailing
`Z`. The `Z` is the only UTC marker — no separate timezone field.

### Error Responses

| Case | Status |
|------|--------|
| Valid body | 201 |
| `for` missing, wrong type, or not a valid duration string | 422 Unprocessable Content |
| Body is not valid JSON / wrong content-type | handled by `wisp.require_json` (415/400) |
| `/wait` with method other than POST | 405 Method Not Allowed (`Allow: POST`) |
| Unknown path | 404 Not Found |

## Duration Grammar (strict)

Format: `"{integer} {unit}"`.

- Exactly **one** ASCII space between number and unit.
- **No** leading or trailing whitespace.
- Unit is **lowercase** only.
- Integer must be **> 0**.
- **Plural agreement** is enforced: `n == 1` requires the singular unit;
  `n >= 2` requires the plural unit.

Accepted units and their fixed second values:

| Unit (singular / plural) | Seconds |
|--------------------------|---------|
| `second` / `seconds`     | 1       |
| `minute` / `minutes`     | 60      |
| `hour` / `hours`         | 3600    |
| `day` / `days`           | 86400   |
| `week` / `weeks`         | 604800  |

`month`/`year` are **not supported**: `gleam_time` has no exact constructor for
them (a month is ~30.4375 days, a year ~365.25 days), so accepting them would
mean shipping a silent approximation. Only units that are exact in `gleam_time`
are allowed; the largest is `week`.

The resulting duration is `duration.seconds(n * seconds_per_unit)`. Erlang
integers are arbitrary precision, so large `n` is fine (JavaScript is not a
build target).

### Examples

```
"5 minutes" -> OK (300s)
"1 minute"  -> OK (60s)
"3 weeks"   -> OK (1_814_400s)
"1 minutes" -> error (plural mismatch)
"2 minute"  -> error (plural mismatch)
"1 Hour"    -> error (uppercase)
" 2 days"   -> error (leading space)
"2  days"   -> error (double space)
"0 seconds" -> error (n must be > 0)
"-3 days"   -> error (n must be > 0)
"5 months"  -> error (unsupported unit)
"abc"       -> error (no number/unit split)
```

## Architecture

Unchanged shape — single HTTP service, no persistence:

```
mist server
  -> wisp_mist handler
    -> router.handle_request
      -> web.middleware
        -> wait.create
          -> wait/duration.parse
```

## Module Layout

```
src/notyet.gleam                            # unchanged
src/notyet/web.gleam                        # unchanged
src/notyet/router.gleam                     # unchanged
src/notyet/wait.gleam                       # request type, decoder, encoder, handler (changed)
src/notyet/wait/duration.gleam              # NEW: strict duration string parser
test/notyet_test.gleam                      # unchanged
test/notyet/wait/duration_unit_test.gleam   # NEW: parser unit tests
test/notyet/wait/decoder_unit_test.gleam    # changed
test/notyet/wait/encoder_unit_test.gleam    # changed
test/notyet/wait/handler_test.gleam         # changed
test/notyet/router_integration_test.gleam   # changed
```

## Components

### `wait/duration.gleam` (new)

Pure parser, no wisp/json dependency:

```
pub fn parse(input: String) -> Result(duration.Duration, Nil)
```

Algorithm:

1. `string.split(input, " ")` must yield exactly `[num, unit]` (this rejects
   leading/trailing/double spaces, since those produce empty parts or a
   different arity).
2. `int.parse(num)` must succeed and be `> 0`.
3. Map `(n, unit)` to seconds, enforcing plural agreement (`n == 1` -> singular
   token, otherwise plural token). Unknown units fail.
4. Return `Ok(duration.seconds(n * seconds_per_unit))`.

Any failure returns `Error(Nil)`.

### `wait.gleam` (changed)

`wait.gleam` imports two modules that would both be named `duration`, so the
project parser is aliased:

```
import gleam/time/duration            // gleam_time: Duration type, .empty, .seconds
import gleam/time/timestamp
import gleam/time/calendar
import notyet/wait/duration as duration_parser   // our parse/1
```

- `WaitRequest(duration: Duration)` — replaces `WaitRequest(wait: String)`. The
  Gleam field is named `duration` because `for` is a reserved word in Gleam; the
  JSON key remains `"for"`. (`Duration` is `gleam/time/duration.Duration`.)
- `duration_decoder() -> decode.Decoder(Duration)`:
  ```
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(d)
    Error(_) -> decode.failure(duration.empty, "valid duration string")
  }
  ```
- `wait_decoder()` = `decode.field("for", duration_decoder())`.
- `encode_response(id: String, created_at: Timestamp, for_time: Timestamp) -> json.Json`:
  ```
  json.object([
    #("id", json.string(id)),
    #("status", json.string("waiting")),
    #("created_at", json.string(timestamp.to_rfc3339(created_at, calendar.utc_offset))),
    #("for", json.string(timestamp.to_rfc3339(for_time, calendar.utc_offset))),
  ])
  ```
  (Local variable named `for_time`, not `for`, since `for` is reserved.)
- `create(req, ctx)` handler:
  1. `wisp.require_method(req, Post)`
  2. `wisp.require_json(req)`
  3. `decode.run(body, wait_decoder())`
     - `Error(_)` -> `wisp.unprocessable_content()` (422)
     - `Ok(WaitRequest(duration:))`:
       - `let now = timestamp.system_time()`
       - `let for_time = timestamp.add(now, duration)`
       - `let id = uuid.v4_string()`
       - `encode_response(id, now, for_time) |> json.to_string |> wisp.json_response(201)`

The `non_empty_string` decoder is removed (its job is now covered by the
duration parser, which rejects `""`).

## Data Flow

```
POST /wait  { "for": "5 minutes" }
  -> middleware
  -> router matches ["wait"], Post
  -> wait.create
  -> require_json -> decode "for" -> duration.parse -> Duration(300s)
  -> now = system_time();  for_time = now + 300s
  -> uuid.v4_string() + status "waiting"
  -> json_response(201)
     { "id": "...", "status": "waiting",
       "created_at": "<now Z>", "for": "<now+300s Z>" }
```

## Testing

### Parser unit tests (`test/notyet/wait/duration_unit_test.gleam`, new)

- `"5 minutes"` -> `Ok(duration.seconds(300))`.
- `"1 minute"` -> `Ok(duration.seconds(60))` (singular).
- `"3 weeks"` -> `Ok(duration.seconds(1_814_400))`.
- Plural mismatch `"1 minutes"` and `"2 minute"` -> `Error`.
- Uppercase `"1 Hour"` -> `Error`.
- Leading/trailing/double space (`" 2 days"`, `"2 days "`, `"2  days"`) -> `Error`.
- `"0 seconds"`, `"-3 days"` -> `Error` (n must be > 0).
- Unsupported unit `"5 months"`, `"1 year"` -> `Error`.
- Garbage `"abc"`, `"5"`, `""` -> `Error`.

### Decoder unit tests (`test/notyet/wait/decoder_unit_test.gleam`, changed)

- `{"for":"5 minutes"}` decodes to `WaitRequest(duration: duration.seconds(300))`.
- `{"for":"bogus"}` is rejected (invalid duration string).
- `{"for":""}` is rejected.
- `{}` (missing `for`) is rejected.
- `{"for":123}` (wrong type) is rejected.
- Extra fields are ignored.

### Encoder unit tests (`test/notyet/wait/encoder_unit_test.gleam`, changed)

- `encode_response` with a fixed `id` and two fixed `Timestamp`s produces an
  object with keys `id`, `status`, `created_at`, `for`.
- `id` and `status` match exactly (`"waiting"`).
- `created_at` and `for` are RFC 3339 strings ending in `Z`.
  (Use fixed timestamps, e.g. `timestamp.from_unix_seconds(...)`, for
  deterministic assertions.)

### Handler tests (`test/notyet/wait/handler_test.gleam`, changed)

Using `wisp/simulate`, body `{"for":"5 minutes"}`:

- Status 201.
- `status` field == `"waiting"`.
- `id` is a parseable, non-empty string.
- `created_at` and `for` are present and end in `Z`.
- Parse both timestamps (`timestamp.parse_rfc3339`) and assert
  `for - created_at == 300s` — verifies the single-`now` invariant.
- `{"for":""}` and `{"for":"5 months"}` -> 422.

### Router integration tests (`test/notyet/router_integration_test.gleam`, changed)

- `POST /wait` with `{"for":"5 minutes"}` -> 201.
- `POST /wait` with invalid duration -> 422.
- `/wait` with non-POST method -> 405.
- Unknown route -> 404.

## Dependencies (`gleam.toml`)

Add `gleam_time = ">= 1.8.0 and < 2.0.0"` to `[dependencies]`. It is already
resolved transitively (via `youid`) at 1.8.0; this makes the direct dependency
explicit. No other dependency changes.

## Out of Scope (YAGNI)

- `month`/`year` units (no exact representation in `gleam_time`).
- Persistence / database.
- Actually waiting, sleeping, or scheduling.
- Authentication, additional endpoints.
- A separate `timezone` response field (the RFC 3339 `Z` already denotes UTC).
- Configurable / non-UTC offsets in the response.
