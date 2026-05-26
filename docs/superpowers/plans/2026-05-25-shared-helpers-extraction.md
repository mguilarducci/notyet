# Shared Helpers Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the UUID-v4 and http-URL validators out of `task.gleam` into a shared `notyet/validate` module, and the duplicated RFC3339 formatter into a shared `notyet/clock` module, with no behavior change.

**Architecture:** Split by concern — input validation (`validate`) vs output formatting (`clock`). Each new module is pure and directly unit-testable. Consumers (`task`, `view`, `batch`) are migrated to the shared functions, and the now-private duplicates plus their orphaned imports are removed.

**Tech Stack:** Gleam 1.16, gleeunit, `youid` (UUID), `gleam/uri`, `gleam/time` (timestamp/calendar).

---

## Background for the implementer

- This repo forbids compound shell commands — **one command per line / per Bash call**. Never chain with `&&` or `;`.
- The test runner is gleeunit: every public function suffixed `_test` in `test/**` is executed by `gleam test`. There is **no single-test filter** — `gleam test` runs the whole suite, which self-provisions a throwaway Postgres via testcontainers (needs a running Docker daemon + Elixir). The new tests in this plan are pure (no DB), but the suite still boots the DB because other tests need it.
- TDD in a compiled language: a test that imports a not-yet-created module fails by **failing to compile**. That compile failure is a valid "red".
- CI enforces `gleam format --check src test` and `gleam build --warnings-as-errors`. Unused (orphaned) imports are compile errors under `--warnings-as-errors`, so removing them is mandatory, not cosmetic.
- Current helper locations (verbatim, to be moved unchanged):
  - `src/notyet/task.gleam:36-45` — `parse_uuid_v4`
  - `src/notyet/task.gleam:49-59` — `parse_http_url`
  - `src/notyet/view.gleam:35-37` and `src/notyet/task/batch.gleam:253-255` — identical private `rfc3339`

---

## Task 1: Create `notyet/validate` module

**Files:**
- Create: `src/notyet/validate.gleam`
- Test: `test/notyet/validate_unit_test.gleam`

This task adds the new module and its direct tests. `task.gleam` is **not** touched yet — it keeps its own private copies for now, so the project still compiles and all existing tests stay green.

- [ ] **Step 1: Write the failing test**

Create `test/notyet/validate_unit_test.gleam`:

```gleam
import gleam/result
import notyet/validate

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

pub fn url_http_rejects_garbage_test() {
  assert validate.url_http("not a url") |> result.is_error
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `gleam test`
Expected: FAIL — compile error, `module notyet/validate not found` (or similar "unknown module").

- [ ] **Step 3: Create the module**

Create `src/notyet/validate.gleam`:

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

- [ ] **Step 4: Run the suite to verify it passes**

Run: `gleam test`
Expected: PASS — all `validate_unit_test` functions green; existing suite unaffected.

- [ ] **Step 5: Format and build-check**

Run: `gleam format src test`
Run: `gleam build --warnings-as-errors`
Expected: no diff complaints, no warnings.

- [ ] **Step 6: Commit**

```bash
git add src/notyet/validate.gleam test/notyet/validate_unit_test.gleam
git commit -m "feat(task): add notyet/validate with uuid_v4 and url_http"
```

---

## Task 2: Migrate `task.gleam` to `notyet/validate`

**Files:**
- Modify: `src/notyet/task.gleam`

Switch the call sites, delete the now-duplicate private helpers, and clean up orphaned imports. Behavior is unchanged, so existing tests (`decoder_unit_test`, `handler_test`, `router_integration_test`) remain the safety net.

- [ ] **Step 1: Add the `validate` import**

In `src/notyet/task.gleam`, add this line to the import block (alphabetical placement, just before `import notyet/task/batch`):

```gleam
import notyet/validate
```

- [ ] **Step 2: Delete the two private helpers**

Delete `parse_uuid_v4` (currently lines 36-45) and `parse_http_url` (currently lines 49-59) in their entirety, including their doc comments.

- [ ] **Step 3: Update the three call sites**

In `destination_decoder`, change:

```gleam
  case parse_http_url(s) {
```
to:
```gleam
  case validate.url_http(s) {
```

In `create`, change:

```gleam
      case parse_uuid_v4(raw_key) {
```
to:
```gleam
      case validate.uuid_v4(raw_key) {
```

In `read`, change:

```gleam
  case parse_uuid_v4(key) {
```
to:
```gleam
  case validate.uuid_v4(key) {
```

- [ ] **Step 4: Remove orphaned imports**

These imports were used only by the deleted helpers. Edit the import block:

- Delete `import gleam/option.{Some}`.
- Delete `import gleam/uri`.
- Change `import youid/uuid.{type Uuid}` to `import youid/uuid` (the `Uuid` type was only referenced in `parse_uuid_v4`'s signature; `uuid.v4`, `uuid.to_string`, and `uuid.from_string` are still used).

- [ ] **Step 5: Build-check to catch any missed orphan**

Run: `gleam build --warnings-as-errors`
Expected: PASS — no "unused import" warnings-as-errors. If it flags an import, that import is now orphaned (or one was removed in error); fix per the message.

- [ ] **Step 6: Run the suite**

Run: `gleam test`
Expected: PASS — `decoder_unit_test`, `handler_test`, `router_integration_test` (the indirect coverage of these validators) all green.

- [ ] **Step 7: Format and commit**

Run: `gleam format src test`

```bash
git add src/notyet/task.gleam
git commit -m "refactor(task): use notyet/validate for uuid/url checks"
```

---

## Task 3: Create `notyet/clock` module

**Files:**
- Create: `src/notyet/clock.gleam`
- Test: `test/notyet/clock_unit_test.gleam`

Adds the shared formatter and its tests. `view.gleam` and `batch.gleam` keep their private copies for now (project still compiles; no dup removed yet).

- [ ] **Step 1: Write the failing test**

Create `test/notyet/clock_unit_test.gleam`:

```gleam
import gleam/time/timestamp
import notyet/clock

// Round-trip: formatting then parsing must recover the exact instant. Mirrors
// the existing view_unit_test approach and is robust to lib formatting details.
pub fn rfc3339_round_trips_test() {
  let t = timestamp.from_unix_seconds(1_000_000)
  let assert Ok(parsed) = timestamp.parse_rfc3339(clock.rfc3339(t))
  assert parsed == t
}

pub fn rfc3339_round_trips_epoch_test() {
  let t = timestamp.from_unix_seconds(0)
  let assert Ok(parsed) = timestamp.parse_rfc3339(clock.rfc3339(t))
  assert parsed == t
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `gleam test`
Expected: FAIL — compile error, `module notyet/clock not found`.

- [ ] **Step 3: Create the module**

Create `src/notyet/clock.gleam`:

```gleam
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// Format a timestamp as RFC3339 in UTC.
pub fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `gleam test`
Expected: PASS — both `clock_unit_test` functions green.

- [ ] **Step 5: Format and build-check**

Run: `gleam format src test`
Run: `gleam build --warnings-as-errors`
Expected: no diff complaints, no warnings.

- [ ] **Step 6: Commit**

```bash
git add src/notyet/clock.gleam test/notyet/clock_unit_test.gleam
git commit -m "feat(task): add notyet/clock rfc3339 formatter"
```

---

## Task 4: Migrate `view.gleam` and `batch.gleam` to `notyet/clock`

**Files:**
- Modify: `src/notyet/view.gleam`
- Modify: `src/notyet/task/batch.gleam`

Replace both private `rfc3339` copies with `clock.rfc3339`, delete the duplicates, and clean orphaned imports. This is the change that actually kills the duplication.

- [ ] **Step 1: Migrate `view.gleam`**

In `src/notyet/view.gleam`:

- Add `import notyet/clock` (alphabetical placement, just before `import notyet/task/status`).
- Delete the private `rfc3339` function (currently lines 35-37) and its doc/comment if any.
- In `encode`, change the two timestamp calls:

```gleam
    #("wait_until", json.string(rfc3339(task.wait_until))),
    #("created_at", json.string(rfc3339(task.created_at))),
```
to:
```gleam
    #("wait_until", json.string(clock.rfc3339(task.wait_until))),
    #("created_at", json.string(clock.rfc3339(task.created_at))),
```

- Delete `import gleam/time/calendar` (it was used only by the deleted `rfc3339`). **Keep** `import gleam/time/timestamp.{type Timestamp}` — the `Timestamp` type is still used in the `Task` record.

- [ ] **Step 2: Migrate `batch.gleam`**

In `src/notyet/task/batch.gleam`:

- Add `import notyet/clock` (alphabetical placement, just before `import notyet/task/record`).
- Delete the private `rfc3339` function (currently lines 253-255).
- In `do_insert`, change the three lines that format timestamps:

```gleam
  let visibles = list.map(records, fn(r) { rfc3339(r.visible_at) })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
```
to:
```gleam
  let visibles = list.map(records, fn(r) { clock.rfc3339(r.visible_at) })
  let untils = list.map(records, fn(r) { clock.rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { clock.rfc3339(r.created_at) })
```

- Delete `import gleam/time/calendar` and `import gleam/time/timestamp` — both were used only by the deleted `rfc3339` (`do_insert` references timestamps only through the now-removed helper).

- [ ] **Step 3: Build-check to catch any missed orphan**

Run: `gleam build --warnings-as-errors`
Expected: PASS — no unused-import warnings. If `gleam/time/timestamp` is flagged as still-needed in `view.gleam`, that means `type Timestamp` is correctly retained there; only `batch.gleam` drops it. If anything is flagged orphaned, remove it.

- [ ] **Step 4: Run the suite**

Run: `gleam test`
Expected: PASS — `view_unit_test` (RFC3339 output) and `batch_test` (insert path) green; the duplication is gone with no behavior change.

- [ ] **Step 5: Format and commit**

Run: `gleam format src test`

```bash
git add src/notyet/view.gleam src/notyet/task/batch.gleam
git commit -m "refactor(task): use notyet/clock for rfc3339, drop duplicate"
```

---

## Task 5: Coverage gate check

**Files:** none (verification only)

- [ ] **Step 1: Run coverage under the dual gate**

Run: `./bin/coverage`
Expected: PASS — exit 0; lines ≥ 80% and clauses ≥ 90%. The new `validate` and `clock` modules now have direct test coverage; the migrated consumers are unchanged. If the gate fails, add the missing case to `validate_unit_test`/`clock_unit_test` (do **not** exclude modules).

- [ ] **Step 2: Confirm a clean tree**

Run: `git status`
Expected: clean working tree; four feature/refactor commits added since the spec commit.

---

## Self-Review

**Spec coverage:**
- `notyet/validate.gleam` with `uuid_v4` + `url_http` → Task 1. ✓
- `notyet/clock.gleam` with `rfc3339` → Task 3. ✓
- `task.gleam` call-site migration + orphan imports (`gleam/uri`, `gleam/option.{Some}`, `type Uuid`) → Task 2. ✓
- `view.gleam` migration + `gleam/time/calendar` removal, keep `type Timestamp` → Task 4 Step 1. ✓
- `batch.gleam` migration + `gleam/time/calendar` & `gleam/time/timestamp` removal → Task 4 Step 2. ✓
- New direct unit tests (validate, clock) → Tasks 1, 3. ✓
- Existing indirect tests stay green → asserted in Tasks 2, 4. ✓
- Dual coverage gate, no exclusions → Task 5. ✓
- Out of scope (`config` `*_var`, `duration`, `status`) → untouched; no task references them. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type/name consistency:** `validate.uuid_v4`, `validate.url_http`, `clock.rfc3339` used identically in definitions (Tasks 1, 3) and call sites (Tasks 2, 4). Signatures match the spec. ✓
