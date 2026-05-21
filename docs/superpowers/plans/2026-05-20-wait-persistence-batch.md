# Activity Field + Batched Postgres Persistence + Docker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a required UUID-v4 `activity` field to `POST /wait` and durably persist every accepted wait to Postgres through an in-memory write-behind batching actor (one `unnest` insert per flush), shipped production-ready with Docker.

**Architecture:** Handler decodes the request, mints `id` + timestamps app-side, builds a `WaitRecord`, and hands it to a supervised batching actor. The actor dams rows in memory and flushes them as one batch insert when the buffer hits `WAIT_BATCH_MAX_SIZE` rows **or** `WAIT_BATCH_INTERVAL_MS` elapses. The handler blocks until its batch commits (ack-on-flush): commit → `201`, failure/timeout → `500`. `status` is a small state machine seeded at `received`. All configuration is mandatory via env (no fallbacks). Docker uses a multi-stage build: full toolchain for migrations, slim Erlang shipment for the app.

**Tech Stack:** Gleam (wisp/mist), `pog` 4.1.0 (Postgres), `squirrel` 4.6.0 (typed queries), `cigogne` 5.0.6 (migrations), `gleam_otp` 1.2.0 (actor + supervisor), `youid` 1.6.0 (UUID), `postgres:18-alpine`, Gleam compiler `v1.16.0`. (All deps verified latest-stable as of 2026-05.)

**Reference implementation:** `../lisztomania-gleam` (same pog/squirrel/cigogne stack, docker-compose, and `test_helper` pattern).

**Spec:** `docs/superpowers/specs/2026-05-20-wait-persistence-batch-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/notyet/wait/status.gleam` | Status state machine (`Received`/`Waiting`), `to_string`/`from_string`. Pure. |
| `src/notyet/wait/record.gleam` | `WaitRecord` type (the row to persist). Pure, no cycle — imported by both `wait` and `batch`. |
| `src/notyet/wait/json_value.gleam` | Add `encode` (existing module). |
| `src/notyet/wait/sql/insert_waits.sql` | Source query for squirrel. |
| `src/notyet/wait/sql.gleam` | **Generated** by squirrel from the `.sql`. |
| `src/notyet/wait/batch.gleam` | Write-behind batching actor: buffer, flush triggers, batch insert, ack replies. |
| `src/notyet/wait.gleam` | `WaitRequest` (+ `raw_for` + `activity`), decoders, `create` handler, response encoder. |
| `src/notyet/web.gleam` | `Context` holds batch `Subject` + `ack_timeout_ms`. |
| `src/notyet.gleam` | Mandatory env, supervised pog pool + batch actor, wiring. |
| `priv/migrations/<ts>-create_waits.sql` | `waits` table migration. |
| `priv/cigogne.toml` | cigogne config. |
| `Dockerfile` | Multi-stage: build (toolchain) + runtime (slim shipment). |
| `docker-compose.yml` | postgres + migrate + app. |
| `.env`, `.env.example`, `.dockerignore`, `Makefile` | Local dev + deploy config. |
| `test/test_helper.gleam` | `start_pool`/`with_db`/`count_waits`/`dummy_subject`. |
| `test/notyet/wait/*_test.gleam`, `test/notyet/router_integration_test.gleam` | Exhaustive tests. |

---

## Task 1: Add dependencies

**Files:**
- Modify: `gleam.toml`

- [ ] **Step 1: Add runtime + dev dependencies**

Edit `gleam.toml`. Under `[dependencies]` add `pog` and `gleam_otp`; under `[dev_dependencies]` add `squirrel` and `cigogne`:

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
pog = ">= 4.1.0 and < 5.0.0"
gleam_otp = ">= 1.2.0 and < 2.0.0"

[dev_dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
squirrel = ">= 4.6.0 and < 5.0.0"
cigogne = ">= 5.0.6 and < 6.0.0"
```

- [ ] **Step 2: Download deps**

Run: `gleam deps download`
Expected: resolves and writes `manifest.toml` with `pog 4.1.0`, `gleam_otp 1.2.0`, `squirrel 4.6.0`, `cigogne 5.0.6` (+ transitive `pgo`, `pg_types`, etc.).

- [ ] **Step 3: Verify it still compiles**

Run: `gleam build`
Expected: builds with no errors (new deps unused so far).

- [ ] **Step 4: Commit**

```bash
git add gleam.toml manifest.toml
git commit -m "build: add pog, gleam_otp, squirrel, cigogne deps"
```

---

## Task 2: Local Postgres + dev config (compose, env, Makefile, cigogne)

This brings up a Postgres reachable from the host so migrations and `gleam test` can run. The app/migrate **container** services are added later (Task 11) once the production Dockerfile exists.

**Files:**
- Create: `docker-compose.yml`, `.env`, `.env.example`, `.dockerignore`, `Makefile`, `priv/cigogne.toml`

- [ ] **Step 1: Write `.env`**

```dotenv
POSTGRES_USER=notyet
POSTGRES_PASSWORD=notyet
POSTGRES_DB=notyet
POSTGRES_HOST_PORT=5434
DATABASE_URL=postgres://notyet:notyet@localhost:5434/notyet
PORT=8000
APP_PORT=8000
SECRET_KEY_BASE=dev_secret_key_base_change_me_min_64_chars_aaaaaaaaaaaaaaaaaaaaaaaa
WAIT_BATCH_MAX_SIZE=50
WAIT_BATCH_INTERVAL_MS=200
WAIT_BATCH_ACK_TIMEOUT_MS=5000
```

> `POSTGRES_HOST_PORT=5434` avoids colliding with a default local Postgres (5432) or lisztomania (5433). `ACK_TIMEOUT (5000) > INTERVAL (200)` — required so requests don't time out before their batch flushes.

- [ ] **Step 2: Write `.env.example`** (same keys, documented placeholders)

```dotenv
# Postgres container
POSTGRES_USER=notyet
POSTGRES_PASSWORD=change_me
POSTGRES_DB=notyet
POSTGRES_HOST_PORT=5434
# App
DATABASE_URL=postgres://notyet:change_me@localhost:5434/notyet
PORT=8000
APP_PORT=8000
SECRET_KEY_BASE=change_me_min_64_chars
# Batch writer (all required; ACK_TIMEOUT must exceed INTERVAL; INTERVAL+insert under pog's 5s query timeout)
WAIT_BATCH_MAX_SIZE=50
WAIT_BATCH_INTERVAL_MS=200
WAIT_BATCH_ACK_TIMEOUT_MS=5000
```

- [ ] **Step 3: Write `.dockerignore`**

```
build/
.git/
.github/
.claude/
.remember/
docs/
*.beam
*.ez
erl_crash.dump
.env
```

- [ ] **Step 4: Write `docker-compose.yml`** (postgres only for now)

```yaml
services:
  postgres:
    image: postgres:18-alpine
    container_name: notyet-postgres
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      - "${POSTGRES_HOST_PORT}:5432"
    volumes:
      - notyet_pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  notyet_pg_data:
```

- [ ] **Step 5: Write `priv/cigogne.toml`**

```toml
[database]
# Falls back to the DATABASE_URL environment variable.

[migration-table]

[migrations]
```

- [ ] **Step 6: Write `Makefile`**

No pipes / `&&` / `;` anywhere — `help` is plain `@echo` lines, one per command:

```makefile
SHELL := /bin/bash
include .env
export

.PHONY: help db-up db-down db-logs migrate migrate-new migrate-rollback migrate-status sqlgen sqlcheck run test build deps

help:
	@echo "db-up            Start Postgres in Docker"
	@echo "db-down          Stop Postgres"
	@echo "db-logs          Tail Postgres logs"
	@echo "migrate          Apply all pending migrations"
	@echo "migrate-new      Create migration (NAME=add_foo)"
	@echo "migrate-rollback Roll back last migration"
	@echo "migrate-status   Show migration state"
	@echo "sqlgen           Generate typed SQL modules"
	@echo "sqlcheck         Verify generated SQL is up to date"
	@echo "run              Run the app"
	@echo "test             Run tests"
	@echo "build            Build the project"
	@echo "deps             Fetch deps"

db-up:
	docker compose up -d postgres

db-down:
	docker compose down

db-logs:
	docker compose logs -f postgres

migrate:
	gleam run -m cigogne all

migrate-new:
	gleam run -m cigogne -- new --name $(NAME)

migrate-rollback:
	gleam run -m cigogne down

migrate-status:
	gleam run -m cigogne show

sqlgen:
	gleam run -m squirrel

sqlcheck:
	gleam run -m squirrel check

run:
	gleam run

test:
	gleam test

build:
	gleam build

deps:
	gleam deps download
```

- [ ] **Step 7: Bring Postgres up**

Run: `make db-up`
Then: `docker compose ps`
Expected: `notyet-postgres` healthy.

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yml .env.example .dockerignore Makefile priv/cigogne.toml
git commit -m "build: docker-compose postgres 18, env config, cigogne, makefile"
```

> `.env` is gitignored (it already matches `.env` in `.gitignore`? if not, add it). Do NOT commit `.env`.

- [ ] **Step 9: Ensure `.env` is ignored**

Read `.gitignore`. If it has no `.env` line, append one (use the Edit/Write tool — not a shell `>>` or `||`). If you changed it, commit:

```bash
git add .gitignore
```
```bash
git commit -m "chore: gitignore .env"
```

---

## Task 3: `waits` table migration

**Files:**
- Create: `priv/migrations/<generated-ts>-create_waits.sql`

- [ ] **Step 1: Generate the migration file**

Run: `make migrate-new NAME=create_waits`
Expected: creates `priv/migrations/<timestamp>-create_waits.sql` with empty `--- migration:up` / `--- migration:down` / `--- migration:end` markers.

- [ ] **Step 2: Fill in the migration**

Replace the generated file's body with (keep the markers cigogne generated):

```sql
--- migration:up
CREATE TABLE waits (
    id           UUID PRIMARY KEY,
    activity     UUID NOT NULL,
    data         JSONB,
    for_duration TEXT NOT NULL,
    wait_until   TIMESTAMPTZ NOT NULL,
    status       TEXT NOT NULL DEFAULT 'received' CHECK (status IN ('received', 'waiting')),
    created_at   TIMESTAMPTZ NOT NULL
);

CREATE INDEX waits_activity_idx ON waits (activity);

--- migration:down
DROP TABLE waits;

--- migration:end
```

- [ ] **Step 3: Apply the migration**

Run: `make migrate`
Expected: reports the migration applied (no error).

- [ ] **Step 4: Verify the table exists**

Run: `docker compose exec postgres psql -U notyet -d notyet -c "\d waits"`
Expected: shows columns `id, activity, data, for_duration, wait_until, status, created_at` with the `status` CHECK.

- [ ] **Step 5: Commit**

```bash
git add priv/migrations
git commit -m "feat(db): add waits table migration"
```

---

## Task 4: Status state machine

**Files:**
- Create: `src/notyet/wait/status.gleam`
- Test: `test/notyet/wait/status_unit_test.gleam`

- [ ] **Step 1: Write the failing test**

`test/notyet/wait/status_unit_test.gleam`:

```gleam
import notyet/wait/status

pub fn to_string_received_test() {
  assert status.to_string(status.Received) == "received"
}

pub fn to_string_waiting_test() {
  assert status.to_string(status.Waiting) == "waiting"
}

pub fn from_string_received_test() {
  assert status.from_string("received") == Ok(status.Received)
}

pub fn from_string_waiting_test() {
  assert status.from_string("waiting") == Ok(status.Waiting)
}

pub fn from_string_unknown_test() {
  assert status.from_string("bogus") == Error(Nil)
}

pub fn round_trip_received_test() {
  assert status.from_string(status.to_string(status.Received)) == Ok(status.Received)
}

pub fn round_trip_waiting_test() {
  assert status.from_string(status.to_string(status.Waiting)) == Ok(status.Waiting)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — `notyet/wait/status` module does not exist.

- [ ] **Step 3: Write the implementation**

`src/notyet/wait/status.gleam`:

```gleam
/// Lifecycle state of a wait. `Received` is the initial state set at creation.
/// `Waiting` is a later state; nothing transitions to it yet (out of scope).
pub type Status {
  Received
  Waiting
}

pub fn to_string(status: Status) -> String {
  case status {
    Received -> "received"
    Waiting -> "waiting"
  }
}

pub fn from_string(value: String) -> Result(Status, Nil) {
  case value {
    "received" -> Ok(Received)
    "waiting" -> Ok(Waiting)
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: PASS (all 7 status tests).

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait/status.gleam test/notyet/wait/status_unit_test.gleam
git commit -m "feat(wait): add status state machine"
```

---

## Task 5: JsonValue encoder

**Files:**
- Modify: `src/notyet/wait/json_value.gleam`
- Test: `test/notyet/wait/json_value_unit_test.gleam` (exists — add cases)

- [ ] **Step 1: Write the failing tests**

Append to `test/notyet/wait/json_value_unit_test.gleam` (add the imports `gleam/json` and `gleam/dynamic/decode` at the top if not present):

```gleam
import gleam/json
import gleam/dynamic/decode
import notyet/wait/json_value.{
  JArray, JBool, JFloat, JInt, JNull, JObject, JString,
}
import gleam/dict

// Round-trip: encode then re-decode must equal the original ADT value.
fn round_trip(value: json_value.JsonValue) -> json_value.JsonValue {
  let assert Ok(decoded) =
    value
    |> json_value.encode
    |> json.to_string
    |> json.parse(json_value.decoder())
  decoded
}

pub fn encode_string_test() {
  let v = JString("hi")
  assert round_trip(v) == v
}

pub fn encode_int_test() {
  let v = JInt(42)
  assert round_trip(v) == v
}

pub fn encode_float_test() {
  let v = JFloat(3.5)
  assert round_trip(v) == v
}

pub fn encode_bool_true_test() {
  assert round_trip(JBool(True)) == JBool(True)
}

pub fn encode_bool_false_test() {
  assert round_trip(JBool(False)) == JBool(False)
}

pub fn encode_null_test() {
  assert round_trip(JNull) == JNull
}

pub fn encode_empty_object_test() {
  let v = JObject(dict.new())
  assert round_trip(v) == v
}

pub fn encode_empty_array_test() {
  assert round_trip(JArray([])) == JArray([])
}

pub fn encode_nested_test() {
  let v =
    JObject(
      dict.from_list([
        #("abc", JInt(1)),
        #("xyz", JArray([JObject(dict.from_list([#("asd", JBool(False))]))])),
      ]),
    )
  assert round_trip(v) == v
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — `json_value.encode` does not exist.

- [ ] **Step 3: Write the implementation**

Add to `src/notyet/wait/json_value.gleam` (add imports `gleam/json` and `gleam/list`):

```gleam
import gleam/json
import gleam/list

/// Serialize a `JsonValue` back to `gleam_json`. Inverse of `decoder()`:
/// `encode |> json.to_string |> json.parse(decoder())` round-trips losslessly.
pub fn encode(value: JsonValue) -> json.Json {
  case value {
    JObject(entries) ->
      entries
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, encode(pair.1)) })
      |> json.object
    JArray(items) -> json.array(items, encode)
    JString(s) -> json.string(s)
    JInt(i) -> json.int(i)
    JFloat(f) -> json.float(f)
    JBool(b) -> json.bool(b)
    JNull -> json.null()
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: PASS (all encoder round-trip tests).

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait/json_value.gleam test/notyet/wait/json_value_unit_test.gleam
git commit -m "feat(wait): add JsonValue encoder for storage"
```

---

## Task 6: `activity` field + `raw_for` on the request decoder

This restructures `WaitRequest` and the decoder. To keep the project compiling, `create` is updated minimally (still no DB; persistence lands in Task 10). The response does not yet include `activity` — that arrives with the rewrite in Task 10. This task is decoder-focused.

**Files:**
- Modify: `src/notyet/wait.gleam`
- Test: `test/notyet/wait/decoder_unit_test.gleam` (exists — add cases)

- [ ] **Step 1: Write the failing tests**

Add to `test/notyet/wait/decoder_unit_test.gleam` (ensure imports: `gleam/dynamic/decode`, `gleam/json`, `gleam/option`, `notyet/wait`, `youid/uuid`). Helper to run the decoder against a JSON string:

```gleam
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import notyet/wait
import youid/uuid

fn decode_body(body: String) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(dynamic) = json.parse(body, decode.dynamic)
  decode.run(dynamic, wait.wait_decoder())
}

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

pub fn valid_activity_v4_test() {
  let assert Ok(req) =
    decode_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
  assert uuid.to_string(req.activity) == v4
  assert req.raw_for == "5 minutes"
  assert req.data == None
}

pub fn activity_missing_test() {
  assert decode_body("{\"for\":\"5 minutes\"}") |> result_is_error
}

pub fn activity_not_a_string_test() {
  assert decode_body("{\"for\":\"5 minutes\",\"activity\":123}") |> result_is_error
}

pub fn activity_not_a_uuid_test() {
  assert decode_body("{\"for\":\"5 minutes\",\"activity\":\"nope\"}") |> result_is_error
}

pub fn activity_uuid_v1_rejected_test() {
  // A valid v1 UUID (version nibble = 1) must be rejected.
  let v1 = "a8098c1a-f86e-11da-bd1a-00112444be1e"
  assert decode_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v1 <> "\"}")
    |> result_is_error
}

pub fn activity_uuid_v7_rejected_test() {
  let v7 = "018f6f6e-7000-7000-8000-000000000000"
  assert decode_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v7 <> "\"}")
    |> result_is_error
}

pub fn raw_for_preserved_verbatim_test() {
  let assert Ok(req) =
    decode_body("{\"for\":\"+5 minutes\",\"activity\":\"" <> v4 <> "\"}")
  assert req.raw_for == "+5 minutes"
}

pub fn bad_for_with_good_activity_test() {
  assert decode_body("{\"for\":\"5 banana\",\"activity\":\"" <> v4 <> "\"}")
    |> result_is_error
}

pub fn valid_with_data_object_test() {
  let assert Ok(req) =
    decode_body(
      "{\"for\":\"1 hour\",\"activity\":\"" <> v4 <> "\",\"data\":{\"k\":1}}",
    )
  assert req.data != None
}

fn result_is_error(r: Result(a, b)) -> Bool {
  case r {
    Ok(_) -> False
    Error(_) -> True
  }
}
```

> If `decoder_unit_test.gleam` already has helpers/imports, merge rather than duplicate. The previous `data`-field tests used `wait_decoder` with the old `WaitRequest`; update those existing cases to include a valid `activity` so they still pass.

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — `WaitRequest` has no `activity`/`raw_for` fields; `wait_decoder` doesn't require `activity`.

- [ ] **Step 3: Update `wait.gleam` types + decoders**

In `src/notyet/wait.gleam`, replace the `WaitRequest` type, `duration_decoder`, and `wait_decoder` with:

```gleam
import youid/uuid.{type Uuid}
// (keep existing imports: gleam/dynamic/decode, gleam/option, gleam/time/duration, etc.)

pub type WaitRequest {
  WaitRequest(
    duration: Duration,
    raw_for: String,
    activity: Uuid,
    data: Option(JsonValue),
  )
}

/// Decodes the "for" field into both the parsed duration and its raw string.
fn for_decoder() -> decode.Decoder(#(Duration, String)) {
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(#(d, s))
    Error(_) -> decode.failure(#(duration.empty, ""), "valid duration string")
  }
}

/// Decodes "activity" as a strict UUID v4. Non-string, non-UUID, or non-v4 fail.
fn activity_decoder() -> decode.Decoder(Uuid) {
  use s <- decode.then(decode.string)
  case uuid.from_string(s) {
    Ok(u) ->
      case uuid.version(u) == uuid.V4 {
        True -> decode.success(u)
        False -> decode.failure(uuid.v4(), "activity must be a UUID v4")
      }
    Error(_) -> decode.failure(uuid.v4(), "activity must be a UUID v4")
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use parsed <- decode.field("for", for_decoder())
  use activity <- decode.field("activity", activity_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    json_value.object_decoder() |> decode.map(Some),
  )
  decode.success(WaitRequest(
    duration: parsed.0,
    raw_for: parsed.1,
    activity: activity,
    data: data,
  ))
}
```

- [ ] **Step 4: Keep `create` compiling (temporary)**

Update the `Ok(...)` arm of `create` to destructure the new shape (still no DB, response unchanged for now):

```gleam
    Ok(WaitRequest(duration: d, raw_for: _, activity: _, data: _)) -> {
      let now = timestamp.system_time()
      let for_time = timestamp.add(now, d)

      uuid.v4_string()
      |> encode_response(now, for_time)
      |> json.to_string
      |> wisp.json_response(201)
    }
```

- [ ] **Step 5: Keep the existing suite green (add activity to old POST bodies)**

Making `activity` required breaks any existing test that POSTs `/wait` without it. Update every existing `POST /wait` body in these files to include a valid v4 `activity` so they pass with the temporary `create` (these files are fully rewritten in Task 10):

- `test/notyet/wait/handler_test.gleam` — add `,"activity":"f47ac10b-58cc-4372-a567-0e02b2c3d479"` to each request body.
- `test/notyet/router_integration_test.gleam` — same for any `/wait` POST body.
- `test/notyet/wait/decoder_unit_test.gleam` — any pre-existing `data`-field cases that omit `activity` must add it (or assert error if testing the no-activity path).

The old `handler_test`/`router` still use the empty `web.Context` (unchanged until Task 10), so no other edits are needed here.

- [ ] **Step 6: Run tests to verify they pass**

Run: `gleam test`
Expected: PASS — all new decoder tests + existing suite green.

- [ ] **Step 7: Commit**

```bash
git add src/notyet/wait.gleam test/notyet/wait/decoder_unit_test.gleam test/notyet/wait/handler_test.gleam test/notyet/router_integration_test.gleam
git commit -m "feat(wait): require activity (uuid v4) and capture raw_for"
```

---

## Task 7: `WaitRecord` type

**Files:**
- Create: `src/notyet/wait/record.gleam`

(No standalone test — exercised by the batch and handler tests. This is a pure type module.)

- [ ] **Step 1: Write the module**

`src/notyet/wait/record.gleam`:

```gleam
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import youid/uuid.{type Uuid}

/// A fully-formed wait ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer and the response encoder.
pub type WaitRecord {
  WaitRecord(
    id: Uuid,
    activity: Uuid,
    data: Option(JsonValue),
    for_duration: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
```

- [ ] **Step 2: Verify it compiles**

Run: `gleam build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add src/notyet/wait/record.gleam
git commit -m "feat(wait): add WaitRecord type"
```

---

## Task 8: Batch insert query (squirrel)

**Files:**
- Create: `src/notyet/wait/sql/insert_waits.sql`
- Generated: `src/notyet/wait/sql.gleam`
- Test: `test/test_helper.gleam` (new), `test/notyet/wait/sql_integration_test.gleam` (new)

> Requires Postgres up (Task 2) and the migration applied (Task 3) — squirrel introspects the live DB.

- [ ] **Step 1: Write the source query**

`src/notyet/wait/sql/insert_waits.sql`:

```sql
INSERT INTO waits (id, activity, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
  AS t(i, a, d, f, w, c)
RETURNING id;
```

- [ ] **Step 2: Generate the typed module**

Run: `make sqlgen`
Expected: creates `src/notyet/wait/sql.gleam` with a function:

```gleam
pub fn insert_waits(
  db: pog.Connection,
  arg_1: List(String),  // ids
  arg_2: List(String),  // activities
  arg_3: List(String),  // data (json or "")
  arg_4: List(String),  // for_duration
  arg_5: List(String),  // wait_until (rfc3339)
  arg_6: List(String),  // created_at (rfc3339)
) -> Result(pog.Returned(InsertWaitsRow), pog.QueryError)
```

> If squirrel infers a different param ordering or type than `List(String)`, adapt the test and the Task 9 actor call to the actual generated signature. The `::text[]` casts are specifically there to make squirrel emit `List(String)` params.

- [ ] **Step 3: Write `test/test_helper.gleam`**

```gleam
import envoy
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import pog

pub fn start_pool() -> pog.Connection {
  let assert Ok(database_url) = envoy.get("DATABASE_URL")
    as "DATABASE_URL must be set for integration tests"

  let pool_name = process.new_name("test_db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, database_url)
    as "DATABASE_URL is not a valid pog url"
  let db_config = pog.pool_size(db_config, 1)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.start
    as "failed to start test db pool"

  pog.named_connection(pool_name)
}

pub fn with_db(test_fn: fn(pog.Connection) -> Nil) -> Nil {
  let db = start_pool()
  let assert Ok(_) =
    "TRUNCATE waits RESTART IDENTITY CASCADE"
    |> pog.query
    |> pog.execute(db)
    as "TRUNCATE waits failed — did you run `make migrate`?"
  test_fn(db)
}

pub fn count_waits(db: pog.Connection) -> Int {
  let assert Ok(pog.Returned(_, [count])) =
    "SELECT count(*)::int FROM waits"
    |> pog.query
    |> pog.returning({
      use n <- decode.field(0, decode.int)
      decode.success(n)
    })
    |> pog.execute(db)
  count
}

// A connection handle bound to an unstarted pool — safe to embed in a Context
// for router-only tests that never query the database.
pub fn dummy_connection() -> pog.Connection {
  process.new_name("dummy_unused_pool")
  |> pog.named_connection
}
```

Add at the top: `import gleam/dynamic/decode`.

- [ ] **Step 4: Write the failing sql integration test**

`test/notyet/wait/sql_integration_test.gleam`:

```gleam
import gleam/list
import notyet/wait/sql
import pog
import test_helper

const v4_a = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

const ts = "2026-05-20T12:00:00Z"

pub fn insert_two_rows_test() {
  use db <- test_helper.with_db

  let assert Ok(pog.Returned(count, rows)) =
    sql.insert_waits(
      db,
      [v4_a, v4_b],
      [v4_a, v4_b],
      ["{\"k\":1}", ""],
      ["5 minutes", "1 hour"],
      [ts, ts],
      [ts, ts],
    )

  assert count == 2
  assert list.length(rows) == 2
  assert test_helper.count_waits(db) == 2
}

pub fn insert_single_row_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(db, [v4_a], [v4_a], [""], ["1 day"], [ts], [ts])
  assert count == 1
}

pub fn empty_data_becomes_null_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], [""], ["1 day"], [ts], [ts])

  // data column is SQL NULL for the empty-string sentinel.
  let assert Ok(pog.Returned(_, [is_null])) =
    "SELECT (data IS NULL) FROM waits"
    |> pog.query
    |> pog.returning({
      use b <- decode.field(0, decode.bool)
      decode.success(b)
    })
    |> pog.execute(db)
  assert is_null == True
}

pub fn empty_list_no_op_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(db, [], [], [], [], [], [])
  assert count == 0
  assert test_helper.count_waits(db) == 0
}
```

Add `import gleam/dynamic/decode` at the top.

- [ ] **Step 5: Run tests to verify they pass**

Run: `make migrate` (ensure table exists), then `gleam test`
Expected: PASS — rows inserted, NULL sentinel works, empty list is a clean no-op.

> Run tests via `make test` — the Makefile's `test` target inherits `.env` via `include`/`export`, so `DATABASE_URL` is set. (Avoid manually chaining `source .env; gleam test`; use the make target, which is a single command.)

- [ ] **Step 6: Commit**

```bash
git add src/notyet/wait/sql/insert_waits.sql src/notyet/wait/sql.gleam test/test_helper.gleam test/notyet/wait/sql_integration_test.gleam
git commit -m "feat(wait): batch insert_waits query + sql integration tests"
```

---

## Task 9: Batch writer actor

**Files:**
- Create: `src/notyet/wait/batch.gleam`
- Test: `test/notyet/wait/batch_test.gleam`

- [ ] **Step 1: Write the actor module**

`src/notyet/wait/batch.gleam`:

```gleam
import gleam/erlang/process.{type Subject, type Timer}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/time/calendar
import gleam/time/timestamp
import gleam/json
import notyet/wait/json_value
import notyet/wait/record.{type WaitRecord}
import notyet/wait/sql
import pog
import youid/uuid

/// Reply sent to a waiter once its batch commits (Ok) or fails (Error).
pub type Ack =
  Result(Nil, Nil)

pub opaque type Message {
  Enqueue(record: WaitRecord, reply: Subject(Ack))
  FlushTick
}

pub type Config {
  Config(max_size: Int, interval_ms: Int)
}

type Pending =
  #(WaitRecord, Subject(Ack))

type State {
  State(
    db: pog.Connection,
    config: Config,
    self: Subject(Message),
    pending: List(Pending),
    timer: Option(Timer),
  )
}

/// Start an unnamed writer (used by tests). Returns the subject to send to.
pub fn start(
  db: pog.Connection,
  config: Config,
) -> actor.StartResult(Subject(Message)) {
  builder(db, config) |> actor.start
}

/// A supervised, named writer (used by the app). The parent recovers the
/// subject via `process.named_subject(name)`.
pub fn supervised(
  name: process.Name(Message),
  db: pog.Connection,
  config: Config,
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { builder(db, config) |> actor.named(name) |> actor.start })
}

fn builder(
  db: pog.Connection,
  config: Config,
) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    actor.initialised(State(
      db: db,
      config: config,
      self: self,
      pending: [],
      timer: None,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
}

/// Enqueue without blocking; returns the reply subject to await later.
pub fn enqueue_async(
  subject: Subject(Message),
  record: WaitRecord,
) -> Subject(Ack) {
  let reply = process.new_subject()
  process.send(subject, Enqueue(record, reply))
  reply
}

/// Enqueue and block until the batch commits or `timeout_ms` elapses.
/// Commit -> Ok(Nil); flush failure or timeout -> Error(Nil).
pub fn enqueue(
  subject: Subject(Message),
  record: WaitRecord,
  timeout_ms: Int,
) -> Ack {
  let reply = enqueue_async(subject, record)
  case process.receive(reply, timeout_ms) {
    Ok(ack) -> ack
    Error(Nil) -> Error(Nil)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    FlushTick -> flush(state)
    Enqueue(record, reply) -> {
      let was_empty = list.is_empty(state.pending)
      let pending = [#(record, reply), ..state.pending]
      let state = State(..state, pending: pending)

      let state = case was_empty {
        True ->
          State(
            ..state,
            timer: Some(process.send_after(
              state.self,
              state.config.interval_ms,
              FlushTick,
            )),
          )
        False -> state
      }

      case list.length(pending) >= state.config.max_size {
        True -> flush(state)
        False -> actor.continue(state)
      }
    }
  }
}

fn flush(state: State) -> actor.Next(State, Message) {
  cancel_timer(state.timer)
  case state.pending {
    [] -> actor.continue(State(..state, timer: None))
    pending -> {
      let records = list.reverse(pending)
      let ack = case do_insert(state.db, list.map(records, fn(p) { p.0 })) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(Nil)
      }
      list.each(records, fn(p) { process.send(p.1, ack) })
      actor.continue(State(..state, pending: [], timer: None))
    }
  }
}

fn cancel_timer(timer: Option(Timer)) -> Nil {
  case timer {
    Some(t) -> {
      process.cancel_timer(t)
      Nil
    }
    None -> Nil
  }
}

fn do_insert(
  db: pog.Connection,
  records: List(WaitRecord),
) -> Result(pog.Returned(sql.InsertWaitsRow), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let activities = list.map(records, fn(r) { uuid.to_string(r.activity) })
  let datas = list.map(records, fn(r) { data_string(r.data) })
  let fors = list.map(records, fn(r) { r.for_duration })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_waits(db, ids, activities, datas, fors, untils, createds)
}

fn data_string(data: Option(json_value.JsonValue)) -> String {
  case data {
    Some(value) -> value |> json_value.encode |> json.to_string
    None -> ""
  }
}

fn rfc3339(t) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
```

- [ ] **Step 2: Write the failing tests**

`test/notyet/wait/batch_test.gleam`:

```gleam
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/timestamp
import notyet/wait/batch
import notyet/wait/json_value.{JInt, JObject}
import notyet/wait/record
import test_helper
import youid/uuid
import gleam/dict

fn rec() -> record.WaitRecord {
  record.WaitRecord(
    id: uuid.v4(),
    activity: uuid.v4(),
    data: None,
    for_duration: "5 minutes",
    wait_until: timestamp.system_time(),
    created_at: timestamp.system_time(),
  )
}

fn rec_with_id(id: uuid.Uuid) -> record.WaitRecord {
  record.WaitRecord(..rec(), id: id)
}

pub fn flush_by_size_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 3, interval_ms: 60_000))

  // Fire 3 async (non-blocking); the 3rd hits max_size and triggers the flush.
  let r1 = batch.enqueue_async(subject, rec())
  let r2 = batch.enqueue_async(subject, rec())
  let r3 = batch.enqueue_async(subject, rec())

  assert process.receive(r1, 5000) == Ok(Ok(Nil))
  assert process.receive(r2, 5000) == Ok(Ok(Nil))
  assert process.receive(r3, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 3
}

pub fn flush_by_interval_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 100, interval_ms: 150))

  let r = batch.enqueue_async(subject, rec())
  // Below max_size; only the interval timer flushes it.
  assert process.receive(r, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 1
}

pub fn no_flush_below_threshold_then_flush_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 3, interval_ms: 60_000))

  let r1 = batch.enqueue_async(subject, rec())
  let r2 = batch.enqueue_async(subject, rec())
  // Only 2 of 3, long interval: nothing should commit yet.
  assert process.receive(r1, 300) == Error(Nil)

  // The 3rd triggers an immediate flush; all three commit.
  let r3 = batch.enqueue_async(subject, rec())
  assert process.receive(r3, 5000) == Ok(Ok(Nil))
  assert process.receive(r1, 5000) == Ok(Ok(Nil))
  assert process.receive(r2, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 3
}

pub fn multiple_batches_test() {
  use db <- test_helper.with_db
  // Short interval so the trailing partial batch flushes quickly (keep the
  // suite fast — do NOT use a multi-second interval here).
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 2, interval_ms: 200))

  let replies = [
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
  ]
  // 5 rows, max_size 2 -> two full flushes (4 rows) at the size threshold; the
  // 5th flushes after the 200ms interval. All commit; all waiters get Ok.
  list.each(replies, fn(r) { assert process.receive(r, 5000) == Ok(Ok(Nil)) })
  assert test_helper.count_waits(db) == 5
}

pub fn flush_error_propagates_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 60_000))

  let id = uuid.v4()
  // First insert of this id succeeds.
  let r1 = batch.enqueue_async(subject, rec_with_id(id))
  assert process.receive(r1, 5000) == Ok(Ok(Nil))

  // Second insert with the same primary key fails -> waiter gets Error.
  let r2 = batch.enqueue_async(subject, rec_with_id(id))
  assert process.receive(r2, 5000) == Ok(Error(Nil))
  assert test_helper.count_waits(db) == 1
}

pub fn data_persisted_as_jsonb_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 60_000))

  let r =
    record.WaitRecord(
      ..rec(),
      data: Some(JObject(dict.from_list([#("k", JInt(1))]))),
    )
  let reply = batch.enqueue_async(subject, r)
  assert process.receive(reply, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 1
}
```

Add imports at top: `import gleam/list`, `import gleam/otp/actor`.

- [ ] **Step 3: Run tests to verify they fail then pass**

Run: `gleam test`
First: FAIL if module/signatures incomplete. Fix compile errors (esp. the `uuid_string` helper note in Step 1).
Then: PASS — every flush trigger, the threshold boundary, multi-batch, the error path, and JSONB persistence.

> `flush_error_propagates_test` relies on the PK unique violation surfacing as `Error` from `do_insert`. If the duplicate insert instead aborts the whole pool connection, scope it: the test still asserts `r2` receives `Error(Nil)` and the row count stays 1.

- [ ] **Step 4: Commit**

```bash
git add src/notyet/wait/batch.gleam test/notyet/wait/batch_test.gleam
git commit -m "feat(wait): write-behind batching actor with size/interval flush"
```

---

## Task 10: Wire persistence end-to-end (Context, app, handler)

**Files:**
- Modify: `src/notyet/web.gleam`, `src/notyet.gleam`, `src/notyet/wait.gleam`
- Test: `test/notyet/wait/handler_test.gleam`, `test/notyet/router_integration_test.gleam`

- [ ] **Step 1: Update `Context`**

`src/notyet/web.gleam`:

```gleam
import gleam/erlang/process
import notyet/wait/batch
import wisp

pub type Context {
  Context(batch: process.Subject(batch.Message), ack_timeout_ms: Int)
}

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  handle_request(req)
}
```

- [ ] **Step 2: Update handler tests (failing)**

Replace `test/notyet/wait/handler_test.gleam` so it builds a real writer + DB context. Helper:

```gleam
import gleam/http
import gleam/json
import gleam/dynamic/decode
import gleam/otp/actor
import notyet/wait
import notyet/web
import notyet/wait/batch
import test_helper
import wisp/simulate

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn ctx_with_writer(db) -> web.Context {
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 200))
  web.Context(batch: subject, ack_timeout_ms: 5000)
}

fn body(json_string: String) {
  simulate.request(http.Post, "/wait") |> simulate.json_body(json_string)
}

pub fn create_persists_and_returns_201_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)

  let response =
    body("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
    |> wait.create(ctx)

  assert response.status == 201
  assert test_helper.count_waits(db) == 1
}

pub fn create_with_data_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    body(
      "{\"for\":\"1 hour\",\"activity\":\"" <> v4 <> "\",\"data\":{\"k\":1}}",
    )
    |> wait.create(ctx)
  assert response.status == 201
  assert test_helper.count_waits(db) == 1
}

pub fn create_missing_activity_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response = body("{\"for\":\"5 minutes\"}") |> wait.create(ctx)
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn create_non_v4_activity_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let v7 = "018f6f6e-7000-7000-8000-000000000000"
  let response =
    body("{\"for\":\"5 minutes\",\"activity\":\"" <> v7 <> "\"}")
    |> wait.create(ctx)
  assert response.status == 422
}

pub fn create_bad_for_422_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    body("{\"for\":\"5 banana\",\"activity\":\"" <> v4 <> "\"}")
    |> wait.create(ctx)
  assert response.status == 422
}

pub fn response_contains_activity_and_received_status_test() {
  use db <- test_helper.with_db
  let ctx = ctx_with_writer(db)
  let response =
    body("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
    |> wait.create(ctx)

  let body_string = simulate.read_body(response)
  let assert Ok(activity) =
    json.parse(body_string, {
      use a <- decode.field("activity", decode.string)
      decode.success(a)
    })
  assert activity == v4

  let assert Ok(status) =
    json.parse(body_string, {
      use s <- decode.field("status", decode.string)
      decode.success(s)
    })
  assert status == "received"
}
```

- [ ] **Step 3: Run to verify failure**

Run: `gleam test`
Expected: FAIL — `wait.create` doesn't take a writer context / doesn't persist / response lacks `activity`.

- [ ] **Step 4: Rewrite `create` + response encoder**

In `src/notyet/wait.gleam`, replace `encode_response` and `create`:

```gleam
import notyet/wait/batch
import notyet/wait/record
import notyet/wait/status

pub fn encode_response(r: record.WaitRecord) -> json.Json {
  json.object([
    #("id", json.string(uuid.to_string(r.id))),
    #("activity", json.string(uuid.to_string(r.activity))),
    #("status", json.string(status.to_string(status.Received))),
    #(
      "created_at",
      json.string(timestamp.to_rfc3339(r.created_at, calendar.utc_offset)),
    ),
    #(
      "for",
      json.string(timestamp.to_rfc3339(r.wait_until, calendar.utc_offset)),
    ),
  ])
}

pub fn create(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use body <- wisp.require_json(req)

  case decode.run(body, wait_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(wr) -> {
      let now = timestamp.system_time()
      let for_time = timestamp.add(now, wr.duration)
      let row =
        record.WaitRecord(
          id: uuid.v4(),
          activity: wr.activity,
          data: wr.data,
          for_duration: wr.raw_for,
          wait_until: for_time,
          created_at: now,
        )

      case batch.enqueue(ctx.batch, row, ctx.ack_timeout_ms) {
        Ok(_) ->
          row |> encode_response |> json.to_string |> wisp.json_response(201)
        Error(_) -> wisp.internal_server_error()
      }
    }
  }
}
```

Update imports: ensure `notyet/web.{type Context}` is present; remove now-unused references (the old `encode_response` 3-arg signature). The `Context` type comes from `web`.

- [ ] **Step 5: Run handler tests**

Run: `gleam test`
Expected: PASS — persists, 201, 422s, response includes `activity` + `status: "received"`.

- [ ] **Step 6: Update router integration test**

`test/notyet/router_integration_test.gleam` — non-DB routes use a dummy context; the happy path uses a writer. Replace contents:

```gleam
import gleam/http
import gleam/json
import gleam/dynamic/decode
import gleam/otp/actor
import notyet/router
import notyet/web
import notyet/wait/batch
import test_helper
import wisp/simulate

const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn dummy_ctx() -> web.Context {
  // Router-only paths (405/404) never reach the writer.
  let assert Ok(actor.Started(_, subject)) =
    batch.start(test_helper.dummy_connection(), batch.Config(max_size: 1, interval_ms: 200))
  web.Context(batch: subject, ack_timeout_ms: 5000)
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Put, "/wait") |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown")
    |> router.handle_request(dummy_ctx())
  assert response.status == 404
}

pub fn post_wait_happy_path_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 200))
  let ctx = web.Context(batch: subject, ack_timeout_ms: 5000)

  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body("{\"for\":\"5 minutes\",\"activity\":\"" <> v4 <> "\"}")
    |> router.handle_request(ctx)

  assert response.status == 201
  let assert Ok(status) =
    json.parse(simulate.read_body(response), {
      use s <- decode.field("status", decode.string)
      decode.success(s)
    })
  assert status == "received"
  assert test_helper.count_waits(db) == 1
}
```

- [ ] **Step 7: Update `notyet.gleam` wiring (mandatory env + supervisor)**

`src/notyet.gleam`:

```gleam
import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/static_supervisor as supervisor
import mist
import notyet/router
import notyet/web
import notyet/wait/batch
import pog
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(database_url) = envoy.get("DATABASE_URL")
  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")
  let assert Ok(port) = read_int("PORT")
  let assert Ok(max_size) = read_int("WAIT_BATCH_MAX_SIZE")
  let assert Ok(interval_ms) = read_int("WAIT_BATCH_INTERVAL_MS")
  let assert Ok(ack_timeout_ms) = read_int("WAIT_BATCH_ACK_TIMEOUT_MS")

  let pool_name = process.new_name("db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, database_url)
  let db = pog.named_connection(pool_name)

  let batch_name = process.new_name("wait_batch")
  let config = batch.Config(max_size: max_size, interval_ms: interval_ms)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.add(batch.supervised(batch_name, db, config))
    |> supervisor.start

  let batch_subject = process.named_subject(batch_name)
  let ctx = web.Context(batch: batch_subject, ack_timeout_ms: ack_timeout_ms)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

fn read_int(name: String) -> Result(Int, Nil) {
  case envoy.get(name) {
    Ok(value) -> int.parse(value)
    Error(_) -> Error(Nil)
  }
}
```

- [ ] **Step 8: Run the full suite**

Run: `gleam test`
Expected: PASS — handler, router, batch, sql, decoder, status, json_value all green.

- [ ] **Step 9: Smoke-test the running app**

Run: `make migrate` then `make run` (with `.env` loaded). In another shell:

```bash
curl -s -X POST localhost:8000/wait -H 'content-type: application/json' \
  -d '{"for":"5 minutes","activity":"f47ac10b-58cc-4372-a567-0e02b2c3d479"}'
```

Expected: `201` JSON with `id`, `activity` (echoed), `status:"received"`, `created_at`, `for`. Verify a row in `waits` (`make` has no target; use `docker compose exec postgres psql -U notyet -d notyet -c "SELECT id, activity, status FROM waits;"`).

- [ ] **Step 10: Commit**

```bash
git add src/notyet/web.gleam src/notyet.gleam src/notyet/wait.gleam test/notyet/wait/handler_test.gleam test/notyet/router_integration_test.gleam
git commit -m "feat(wait): persist via batch writer; add activity + received status to response"
```

---

## Task 11: Production Dockerfile + compose migrate/app services

**Files:**
- Create: `Dockerfile`
- Modify: `docker-compose.yml`

- [ ] **Step 1: Write the multi-stage `Dockerfile`**

```dockerfile
# --- build stage: full toolchain (compiles + holds dev deps for migrations) ---
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS build

WORKDIR /app
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY . .
RUN gleam export erlang-shipment

# --- runtime stage: slim Erlang, production shipment only ---
FROM erlang:28-alpine AS runtime

WORKDIR /app
COPY --from=build /app/build/erlang-shipment /app

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
```

> The runtime base must provide an OTP major compatible with the build image. `erlang:28-alpine` is the current stable. If the shipment fails to boot with a version error, set the runtime tag to match the OTP in `ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine` (check with `docker run --rm ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell`).

- [ ] **Step 2: Add `migrate` + `app` services to `docker-compose.yml`**

Append to `docker-compose.yml` (the `migrate` service builds the `build` stage so cigogne is present; `app` runs the slim runtime):

```yaml
  migrate:
    build:
      context: .
      target: build
    container_name: notyet-migrate
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
    command: ["gleam", "run", "-m", "cigogne", "all"]

  app:
    build:
      context: .
      target: runtime
    container_name: notyet-app
    depends_on:
      migrate:
        condition: service_completed_successfully
    environment:
      DATABASE_URL: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      PORT: ${APP_PORT}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      WAIT_BATCH_MAX_SIZE: ${WAIT_BATCH_MAX_SIZE}
      WAIT_BATCH_INTERVAL_MS: ${WAIT_BATCH_INTERVAL_MS}
      WAIT_BATCH_ACK_TIMEOUT_MS: ${WAIT_BATCH_ACK_TIMEOUT_MS}
    ports:
      - "${APP_PORT}:${APP_PORT}"
```

> The `migrate` service `command` includes a `gleam build` implicitly via `gleam run`. `cigogne all` reads `priv/cigogne.toml` + `DATABASE_URL`. The migration files in `priv/migrations` are copied in the build stage.

- [ ] **Step 3: Build and run the full stack**

Run: `docker compose down -v` (clean), then `docker compose up --build`
Expected: `postgres` healthy → `migrate` applies the migration and exits `0` → `app` boots and serves on `APP_PORT`.

- [ ] **Step 4: Verify the containerized app**

```bash
curl -s -X POST localhost:8000/wait -H 'content-type: application/json' \
  -d '{"for":"10 minutes","activity":"f47ac10b-58cc-4372-a567-0e02b2c3d479"}'
```

Expected: `201` with `status:"received"`. Then `docker compose exec postgres psql -U notyet -d notyet -c "SELECT count(*) FROM waits;"` shows the row.

- [ ] **Step 5: Tear down**

Run: `docker compose down`

- [ ] **Step 6: Commit**

```bash
git add Dockerfile docker-compose.yml
git commit -m "build: production multi-stage Dockerfile + migrate/app compose services"
```

---

## Task 12: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the architecture + contract docs**

Edit `CLAUDE.md`:
- **Commands:** add `make db-up`, `make migrate`, `make sqlgen`, `docker compose up --build`. Note `gleam test` requires Postgres up + migrated (`make db-up && make migrate`).
- **Environment:** `DATABASE_URL`, `WAIT_BATCH_MAX_SIZE`, `WAIT_BATCH_INTERVAL_MS`, `WAIT_BATCH_ACK_TIMEOUT_MS`, `PORT`, `SECRET_KEY_BASE` — all **mandatory** (fallbacks removed; app panics at boot if missing). Note `ACK_TIMEOUT_MS > INTERVAL_MS`.
- **Architecture:** describe the new modules — `wait/status.gleam` (state machine), `wait/record.gleam` (`WaitRecord`), `wait/batch.gleam` (write-behind actor), `wait/sql.gleam` (squirrel), and the supervised pool + writer in `notyet.gleam`.
- **`POST /wait` contract:** now `{"for", "activity" (uuid v4, required), "data"?}` → `201 {id, activity, status:"received", created_at, for}`. Missing/non-v4 `activity` → `422`. Persisted to `waits` via batched write-behind insert; flush fails / ack times out → `500`. `status` is a state machine (`received` initial, `waiting` reserved).
- **Persistence:** pog + squirrel (`make sqlgen` regenerates `sql.gleam`; needs live migrated DB) + cigogne migrations in `priv/migrations`.
- **Testing:** DB-touching tests run against live Postgres via `test/test_helper.gleam`.

- [ ] **Step 2: Verify build + tests still green**

Run: `gleam test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document activity, batched persistence, env, and docker"
```

---

## Final verification

- [ ] `make db-up`, then `make migrate`, then `make test` — full suite green against live Postgres (each its own command, no chaining).
- [ ] `docker compose down -v`, then `docker compose up --build` — postgres → migrate (exit 0) → app serving; `POST /wait` returns `201` and persists.
- [ ] `gleam format --check` — formatting clean.
- [ ] No hardcoded config: every value comes from env (check `src/notyet.gleam` for stray literals).
