# Wait For-Duration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change `POST /wait` to accept a strict human-readable duration in field `for` and return `created_at` and `for` as RFC 3339 UTC timestamps where `for = now + duration`.

**Architecture:** A new pure parser module (`notyet/wait/duration`) turns a `"{n} {unit}"` string into a `gleam_time` `Duration`. The `wait` handler decodes `for` through that parser, captures a single `now`, and emits both timestamps via `timestamp.to_rfc3339(_, calendar.utc_offset)`.

**Tech Stack:** Gleam, wisp/mist, gleam_json, gleam/dynamic/decode, gleam_time (`duration`, `timestamp`, `calendar`), youid, gleeunit + wisp/simulate.

**Spec:** `docs/superpowers/specs/2026-05-20-wait-for-duration-design.md`

---

## File Structure

- Create: `src/notyet/wait/duration.gleam` — strict duration string parser (`parse/1`), pure, no wisp/json.
- Create: `test/notyet/wait/duration_unit_test.gleam` — parser unit tests.
- Modify: `gleam.toml` — add `gleam_time` direct dependency.
- Modify: `src/notyet/wait.gleam` — `for` field, duration decoder, 4-field encoder, timestamp-computing handler.
- Modify: `test/notyet/wait/decoder_unit_test.gleam` — new `for`/duration expectations.
- Modify: `test/notyet/wait/encoder_unit_test.gleam` — 4-field shape with timestamps.
- Modify: `test/notyet/wait/handler_test.gleam` — duration body + timestamp invariant.
- Modify: `test/notyet/router_integration_test.gleam` — `for` body.

---

## Task 1: Add gleam_time dependency

**Files:**
- Modify: `gleam.toml`

- [ ] **Step 1: Add the dependency line**

In `gleam.toml`, add `gleam_time` to `[dependencies]` (keep alphabetical-ish grouping is not required; place after `envoy`):

```toml
[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
wisp = ">= 2.2.2 and < 3.0.0"
mist = ">= 6.0.3 and < 7.0.0"
gleam_json = ">= 3.1.0 and < 4.0.0"
gleam_http = ">= 4.3.0 and < 5.0.0"
gleam_erlang = ">= 1.3.0 and < 2.0.0"
youid = ">= 1.6.0 and < 2.0.0"
envoy = ">= 1.2.0 and < 2.0.0"
gleam_time = ">= 1.8.0 and < 2.0.0"
```

- [ ] **Step 2: Resolve dependencies**

Run: `gleam deps download`
Expected: succeeds; `gleam_time` already resolves to 1.8.0 (it is present transitively via `youid`), so no version conflict.

- [ ] **Step 3: Verify build still compiles**

Run: `gleam build`
Expected: compiles with no errors.

- [ ] **Step 4: Commit**

```bash
git add gleam.toml manifest.toml
git commit -m "build(wait): add gleam_time direct dependency"
```

---

## Task 2: Duration parser module

**Files:**
- Create: `src/notyet/wait/duration.gleam`
- Test: `test/notyet/wait/duration_unit_test.gleam`

- [ ] **Step 1: Write the failing tests**

Create `test/notyet/wait/duration_unit_test.gleam`:

```gleam
import gleam/result
import gleam/time/duration
import notyet/wait/duration as parser

pub fn seconds_singular_test() {
  assert parser.parse("1 second") == Ok(duration.seconds(1))
}

pub fn minutes_plural_test() {
  assert parser.parse("5 minutes") == Ok(duration.seconds(300))
}

pub fn hour_singular_test() {
  assert parser.parse("1 hour") == Ok(duration.seconds(3600))
}

pub fn days_plural_test() {
  assert parser.parse("2 days") == Ok(duration.seconds(172_800))
}

pub fn weeks_plural_test() {
  assert parser.parse("3 weeks") == Ok(duration.seconds(1_814_400))
}

pub fn plural_with_singular_unit_rejected_test() {
  assert parser.parse("2 minute") |> result.is_error
}

pub fn singular_with_plural_unit_rejected_test() {
  assert parser.parse("1 minutes") |> result.is_error
}

pub fn uppercase_unit_rejected_test() {
  assert parser.parse("1 Hour") |> result.is_error
}

pub fn leading_space_rejected_test() {
  assert parser.parse(" 2 days") |> result.is_error
}

pub fn trailing_space_rejected_test() {
  assert parser.parse("2 days ") |> result.is_error
}

pub fn double_space_rejected_test() {
  assert parser.parse("2  days") |> result.is_error
}

pub fn zero_rejected_test() {
  assert parser.parse("0 seconds") |> result.is_error
}

pub fn negative_rejected_test() {
  assert parser.parse("-3 days") |> result.is_error
}

pub fn month_unit_rejected_test() {
  assert parser.parse("5 months") |> result.is_error
}

pub fn year_unit_rejected_test() {
  assert parser.parse("1 year") |> result.is_error
}

pub fn garbage_rejected_test() {
  assert parser.parse("abc") |> result.is_error
}

pub fn number_only_rejected_test() {
  assert parser.parse("5") |> result.is_error
}

pub fn empty_rejected_test() {
  assert parser.parse("") |> result.is_error
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test`
Expected: FAIL — module `notyet/wait/duration` does not exist (compile error).

- [ ] **Step 3: Write the parser implementation**

Create `src/notyet/wait/duration.gleam`:

```gleam
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: PASS — all parser tests green.

- [ ] **Step 5: Format**

Run: `gleam format`
Expected: no changes (or formats the new files).

- [ ] **Step 6: Commit**

```bash
git add src/notyet/wait/duration.gleam test/notyet/wait/duration_unit_test.gleam
git commit -m "feat(wait): add strict human-readable duration parser"
```

---

## Task 3: Rewrite wait.gleam (decoder, encoder, handler) and update tests

`wait.gleam` is a single tightly-coupled module: renaming the request field to a
parsed `Duration` changes the type, decoder, encoder signature, and handler
together. Update its three test files and the router test in the same task so
the suite compiles and runs.

**Files:**
- Modify: `src/notyet/wait.gleam`
- Test: `test/notyet/wait/decoder_unit_test.gleam`
- Test: `test/notyet/wait/encoder_unit_test.gleam`
- Test: `test/notyet/wait/handler_test.gleam`
- Test: `test/notyet/router_integration_test.gleam`

- [ ] **Step 1: Update the test files to the new API (red)**

Replace `test/notyet/wait/decoder_unit_test.gleam` with:

```gleam
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/time/duration
import notyet/wait

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300))
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"for\":\"bogus\"}") |> result.is_error
}

pub fn empty_for_rejected_test() {
  assert decode_json("{\"for\":\"\"}") |> result.is_error
}

pub fn missing_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"for\":123}") |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\",\"extra\":\"x\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300))
}
```

Replace `test/notyet/wait/encoder_unit_test.gleam` with:

```gleam
import gleam/json
import gleam/string
import gleam/time/timestamp
import notyet/wait

pub fn encode_response_shape_test() {
  let created_at = timestamp.from_unix_seconds(1000)
  let for_time = timestamp.from_unix_seconds(1300)
  let output =
    wait.encode_response("abc-123", created_at, for_time)
    |> json.to_string

  assert string.contains(output, "\"id\":\"abc-123\"")
  assert string.contains(output, "\"status\":\"waiting\"")
  assert string.contains(output, "\"created_at\":\"1970-01-01T00:16:40Z\"")
  assert string.contains(output, "\"for\":\"1970-01-01T00:21:40Z\"")
}
```

Replace `test/notyet/wait/handler_test.gleam` with:

```gleam
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import notyet/wait
import notyet/web
import wisp/simulate

fn post(body_json: json.Json) {
  simulate.request(http.Post, "/wait")
  |> simulate.json_body(body_json)
  |> wait.create(web.Context)
}

fn read_field(response, field) {
  let assert Ok(value) =
    simulate.read_body(response)
    |> json.parse(decode.at([field], decode.string))
  value
}

pub fn valid_post_returns_201_test() {
  let response = post(json.object([#("for", json.string("5 minutes"))]))
  assert response.status == 201
}

pub fn response_status_field_is_waiting_test() {
  let response = post(json.object([#("for", json.string("5 minutes"))]))
  assert read_field(response, "status") == "waiting"
}

pub fn response_id_is_non_empty_test() {
  let response = post(json.object([#("for", json.string("5 minutes"))]))
  assert read_field(response, "id") != ""
}

pub fn timestamps_are_utc_test() {
  let response = post(json.object([#("for", json.string("5 minutes"))]))
  assert string.ends_with(read_field(response, "created_at"), "Z")
  assert string.ends_with(read_field(response, "for"), "Z")
}

pub fn for_is_now_plus_duration_test() {
  let response = post(json.object([#("for", json.string("5 minutes"))]))
  let assert Ok(created_at) =
    timestamp.parse_rfc3339(read_field(response, "created_at"))
  let assert Ok(for_time) =
    timestamp.parse_rfc3339(read_field(response, "for"))
  // difference(left, right) is right - left, so this is for - created_at.
  assert timestamp.difference(created_at, for_time) == duration.seconds(300)
}

pub fn empty_for_returns_422_test() {
  let response = post(json.object([#("for", json.string(""))]))
  assert response.status == 422
}

pub fn month_unit_returns_422_test() {
  let response = post(json.object([#("for", json.string("5 months"))]))
  assert response.status == 422
}
```

Replace `test/notyet/router_integration_test.gleam` with:

```gleam
import gleam/http
import gleam/json
import notyet/router
import notyet/web
import wisp/simulate

pub fn post_wait_dispatches_to_handler_test() {
  let body = json.object([#("for", json.string("5 minutes"))])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 201
}

pub fn invalid_duration_returns_422_test() {
  let body = json.object([#("for", json.string("nope"))])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 422
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Get, "/wait")
    |> router.handle_request(web.Context)

  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown")
    |> router.handle_request(web.Context)

  assert response.status == 404
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test`
Expected: FAIL — compile errors (`wait.WaitRequest(duration:)` field unknown, `encode_response` arity mismatch). This confirms the tests exercise the new API.

- [ ] **Step 3: Rewrite the implementation**

Replace `src/notyet/wait.gleam` with:

```gleam
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/json
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/duration as duration_parser
import notyet/web.{type Context}
import wisp.{type Request, type Response}
import youid/uuid

pub type WaitRequest {
  WaitRequest(duration: Duration)
}

fn duration_decoder() -> decode.Decoder(Duration) {
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(d)
    Error(_) -> decode.failure(duration.empty, "valid duration string")
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use parsed <- decode.field("for", duration_decoder())
  decode.success(WaitRequest(duration: parsed))
}

pub fn encode_response(
  id: String,
  created_at: Timestamp,
  for_time: Timestamp,
) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("status", json.string("waiting")),
    #(
      "created_at",
      json.string(timestamp.to_rfc3339(created_at, calendar.utc_offset)),
    ),
    #("for", json.string(timestamp.to_rfc3339(for_time, calendar.utc_offset))),
  ])
}

pub fn create(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use body <- wisp.require_json(req)

  case decode.run(body, wait_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(WaitRequest(duration: d)) -> {
      let now = timestamp.system_time()
      let for_time = timestamp.add(now, d)

      uuid.v4_string()
      |> encode_response(now, for_time)
      |> json.to_string
      |> wisp.json_response(201)
    }
  }
}
```

Notes:
- `import notyet/wait/duration as duration_parser` avoids the name clash with
  `gleam/time/duration` (which provides the `Duration` type, `.empty`, `.seconds`).
- `for` is a reserved word in Gleam, so the JSON key is `"for"` while the Gleam
  field and local variable are `duration` / `for_time`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: PASS — all decoder, encoder, handler, router, and parser tests green.

- [ ] **Step 5: Format**

Run: `gleam format`
Expected: no changes.

- [ ] **Step 6: Commit**

```bash
git add src/notyet/wait.gleam test/notyet/wait/decoder_unit_test.gleam test/notyet/wait/encoder_unit_test.gleam test/notyet/wait/handler_test.gleam test/notyet/router_integration_test.gleam
git commit -m "feat(wait): accept for-duration and return created_at/for timestamps"
```

---

## Task 4: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the whole suite**

Run: `gleam test`
Expected: PASS — every `*_test` function across `test/` passes.

- [ ] **Step 2: Verify formatting is clean**

Run: `gleam format --check`
Expected: exit 0, no files would change.

- [ ] **Step 3: Smoke test the running server (optional but recommended)**

Start: `gleam run` (in a background shell), then in another shell:

```bash
curl -s -X POST localhost:8000/wait -H 'content-type: application/json' -d '{"for":"5 minutes"}'
```

Expected: `201` body like
`{"id":"<uuid>","status":"waiting","created_at":"...Z","for":"...Z"}` where the
`for` timestamp is 300 seconds after `created_at`.

```bash
curl -s -o /dev/null -w '%{http_code}' -X POST localhost:8000/wait -H 'content-type: application/json' -d '{"for":"5 months"}'
```

Expected: `422`.

Stop the server when done.

---

## Self-Review Notes

- **Spec coverage:** field rename `for` (Tasks 2/3), strict grammar incl. plural
  agreement and unsupported month/year (Task 2 tests + parser), `created_at`/`for`
  RFC 3339 UTC with single `now` (Task 3 handler + `for_is_now_plus_duration_test`),
  `Z`-only UTC marker (`timestamps_are_utc_test`), `gleam_time` dependency (Task 1),
  422 on invalid duration (decoder + handler + router tests). All covered.
- **Module clash** between `gleam/time/duration` and `notyet/wait/duration` resolved
  with the `as duration_parser` alias in `wait.gleam` and `as parser` in the unit test.
- **`difference` direction** confirmed: `difference(left, right) = right - left`, so
  `difference(created_at, for_time) == duration.seconds(300)` holds.
