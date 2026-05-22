# task Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the `/wait` feature into `/tasks`: rename `wait`→`task` everywhere, drop the `data` and `activity` fields, rename `for`→`wait_for`, and add a required `destination` URL — backed by a single `create_tasks` migration.

**Architecture:** Three sequential commits, each leaving a compiling, green build. Task 1 is a pure mechanical rename (schema-preserving). Task 2 shrinks the schema (drop `data`/`activity`, rename `for_duration`→`wait_for`). Task 3 adds the new validated `destination` field via TDD. Each task rewrites the single migration, resets the dev DB, and regenerates squirrel against the migrated DB.

**Tech Stack:** Gleam, wisp, mist, pog, squirrel (typed SQL codegen), cigogne (migrations), gleeunit, Postgres.

---

## Critical conventions (read before starting)

- **No compound shell commands** anywhere (one command per line) — repo rule.
- **DB reset** (needed each time the single migration is rewritten):
  - `docker compose down -v` (drops the `notyet_pg_data` volume — `make db-down` alone keeps it)
  - `make db-up`
  - `make migrate`
- `make sqlgen` regenerates `src/notyet/task/sql.gleam` by introspecting the **live, migrated** DB — always run it **after** reset+migrate, **after** the `.sql` files and migration are in their new shape. Never hand-edit `sql.gleam`.
- `make test` requires Postgres up + migrated.
- **Token trap for the rename:** do **NOT** blind-replace the substring `wait`. The tokens `wait_until` (a real column/field) and `for_duration`/`raw_for` (renamed only in Task 2) must survive Task 1 untouched. Replace only the specific identifiers listed.

---

## File map (final state)

**Source (`src/`):**
- `src/notyet.gleam` — entrypoint; env reads renamed `WAIT_*`→`TASK_*`, named process `"task_batch"`.
- `src/notyet/router.gleam` — routes `["tasks"]` / `["tasks", key]`.
- `src/notyet/web.gleam` — `Context` (imports `notyet/task/batch`).
- `src/notyet/task.gleam` — feature module: `TaskRequest`, `task_decoder`, `destination_decoder`, `parse_http_url`, `parse_uuid_v4`, `create`, `read`, `row_to_task`.
- `src/notyet/task/batch.gleam` — coordinator actor; `do_insert` builds the `insert_tasks` arg lists.
- `src/notyet/task/duration.gleam` — duration parser (unchanged logic).
- `src/notyet/task/record.gleam` — `TaskRecord`.
- `src/notyet/task/status.gleam` — `Status` (unchanged logic).
- `src/notyet/task/view.gleam` — `Task` read-model + `encode`.
- `src/notyet/task/sql.gleam` — squirrel-generated (regenerated, not edited).
- `src/notyet/task/sql/insert_tasks.sql`, `src/notyet/task/sql/get_task_by_idempotency_key.sql`.
- **Deleted:** `src/notyet/wait/json_value.gleam` (only consumer was `data`).

**Migrations:**
- `priv/migrations/20260521004749-create_tasks.sql` (the single migration; rewritten each task).

**Tests (`test/`):** mirror under `test/notyet/task/`; delete `json_value_unit_test.gleam`.

**Config:** `.env`, `.env.example`, `docker-compose.yml`, `CLAUDE.md`.

---

## Task 1: Mechanical rename `wait` → `task` (schema-preserving)

No contract change other than the route path (`/wait`→`/tasks`) and the table name (`waits`→`tasks`). `data`, `activity`, `for_duration` all still exist. End state: identical behavior on the new names, all tests green.

**Files:**
- Rename: `src/notyet/wait.gleam` → `src/notyet/task.gleam`
- Rename: `src/notyet/wait/` → `src/notyet/task/` (all 7 `.gleam` + `sql/` dir)
- Rename: `src/notyet/task/sql/insert_waits.sql` → `insert_tasks.sql`
- Rename: `src/notyet/task/sql/get_wait_by_idempotency_key.sql` → `get_task_by_idempotency_key.sql`
- Rename: `test/notyet/wait/` → `test/notyet/task/`
- Rename: `priv/migrations/20260521004749-create_waits.sql` → `...-create_tasks.sql`
- Modify: `src/notyet.gleam`, `src/notyet/router.gleam`, `src/notyet/web.gleam`, all renamed modules, all renamed tests, `test/test_helper.gleam`, `test/notyet_test.gleam`, `test/notyet/router_integration_test.gleam`, `.env`, `.env.example`, `docker-compose.yml`, `CLAUDE.md`.

- [ ] **Step 1: Move source files**

```bash
git mv src/notyet/wait src/notyet/task
```
```bash
git mv src/notyet/wait.gleam src/notyet/task.gleam
```
```bash
git mv src/notyet/task/sql/insert_waits.sql src/notyet/task/sql/insert_tasks.sql
```
```bash
git mv src/notyet/task/sql/get_wait_by_idempotency_key.sql src/notyet/task/sql/get_task_by_idempotency_key.sql
```

- [ ] **Step 2: Move test files**

```bash
git mv test/notyet/wait test/notyet/task
```

- [ ] **Step 3: Rewrite the migration (file rename + table/index rename, same columns)**

```bash
git mv priv/migrations/20260521004749-create_waits.sql priv/migrations/20260521004749-create_tasks.sql
```

Then set `priv/migrations/20260521004749-create_tasks.sql` to:

```sql
--- migration:up
CREATE TABLE tasks (
    id              UUID PRIMARY KEY,
    activity        UUID NOT NULL,
    idempotency_key TEXT NOT NULL,
    data            JSONB,
    for_duration    TEXT NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting')),
    created_at      TIMESTAMPTZ NOT NULL
);

CREATE INDEX tasks_activity_idx ON tasks (activity);
CREATE UNIQUE INDEX tasks_idempotency_key_idx ON tasks (idempotency_key);

--- migration:down
DROP TABLE tasks;

--- migration:end
```

- [ ] **Step 4: Rewrite the two SQL query files (table `waits`→`tasks` only)**

`src/notyet/task/sql/insert_tasks.sql`:

```sql
INSERT INTO tasks (id, activity, idempotency_key, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, k, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, a, k, d, f, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

`src/notyet/task/sql/get_task_by_idempotency_key.sql`:

```sql
SELECT
  id::text,
  activity::text,
  idempotency_key,
  status,
  for_duration,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
  COALESCE(data::text, '') AS data
FROM tasks
WHERE idempotency_key = $1;
```

- [ ] **Step 5: Reset the dev DB and migrate**

```bash
docker compose down -v
```
```bash
make db-up
```
```bash
make migrate
```
Expected: migration `20260521004749-create_tasks` applied; `tasks` table exists.

- [ ] **Step 6: Regenerate squirrel**

```bash
make sqlgen
```
Expected: `src/notyet/task/sql.gleam` regenerated with `GetTaskByIdempotencyKeyRow` and `insert_tasks` (still 7 args; `activity`+`data` present).

- [ ] **Step 7: Apply the identifier renames across `.gleam` + config**

Apply these **exact** replacements in every `.gleam` file under `src/` and `test/`, plus the listed config files. Do **not** touch `wait_until`, `for_duration`, `raw_for`, or prose in doc-comments.

Identifier / literal replacements:

| Old | New |
|-----|-----|
| `notyet/wait/` (import path prefix) | `notyet/task/` |
| `notyet/wait` (import path) | `notyet/task` |
| `WaitRequest` | `TaskRequest` |
| `WaitRecord` | `TaskRecord` |
| `type Wait` / `Wait(` / `view.Wait` (the read-model type + constructor) | `Task` / `Task(` / `view.Task` |
| `wait_decoder` | `task_decoder` |
| `for_decoder` | `for_decoder` (unchanged) |
| `get_wait_by_idempotency_key` | `get_task_by_idempotency_key` |
| `GetWaitByIdempotencyKeyRow` | `GetTaskByIdempotencyKeyRow` |
| `insert_waits` | `insert_tasks` |
| `row_to_wait` | `row_to_task` |
| `"wait_batch"` (named process) | `"task_batch"` |
| route literal `["wait"]` / `["wait", key]` / `["wait", _]` | `["tasks"]` / `["tasks", key]` / `["tasks", _]` |
| `count_waits` | `count_tasks` |
| `TRUNCATE waits` | `TRUNCATE tasks` |
| `WAIT_BATCH_MAX_SIZE` | `TASK_BATCH_MAX_SIZE` |
| `WAIT_BATCH_INTERVAL_MS` | `TASK_BATCH_INTERVAL_MS` |
| `WAIT_BATCH_MAX_IN_FLIGHT` | `TASK_BATCH_MAX_IN_FLIGHT` |
| `WAIT_DB_POOL_SIZE` | `TASK_DB_POOL_SIZE` |
| `WAIT_ENQUEUE_TIMEOUT_MS` | `TASK_ENQUEUE_TIMEOUT_MS` |
| `WAIT_BATCH_ACK_TIMEOUT_MS` (stale ref in docker-compose only) | `TASK_BATCH_ACK_TIMEOUT_MS` |

Notes:
- In `src/notyet/task/view.gleam`, the `encode` parameter is named `wait: Wait` — rename it to `task: Task` and update `wait.id`/`wait.data`/etc. to `task.*`.
- In `src/notyet.gleam`, the `read_int("WAIT_…")` argument strings are the env keys above.
- Update `.env`, `.env.example`, `docker-compose.yml` (lines 43-45), and `CLAUDE.md` env names. (The docker-compose `app` block is already missing `MAX_IN_FLIGHT`/`POOL_SIZE` and uses a stale `ACK_TIMEOUT_MS` — leave that pre-existing gap as-is; only rename the prefixes present.)
- In `CLAUDE.md`: rename the route (`POST /wait`→`POST /tasks`, `GET /wait/{key}`→`GET /tasks/{key}`), the table (`waits`→`tasks`), module paths (`src/notyet/wait*`→`src/notyet/task*`), and the env var names. (Field/contract edits for `data`/`activity`/`for`/`destination` come in Tasks 2-3.)

- [ ] **Step 8: Build**

```bash
make build
```
Expected: compiles with no errors.

- [ ] **Step 9: Run the full suite**

```bash
make test
```
Expected: all tests pass (same count as before; behavior unchanged on the new names).

- [ ] **Step 10: Commit**

```bash
git add -A
```
```bash
git commit -m "refactor(task): rename wait domain to task"
```

---

## Task 2: Drop `data` + `activity`, rename `for` → `wait_for`

Shrink the schema and contract. After this task: the body is `{"wait_for": <duration>}`, the response has no `data`/`activity`, and the duration column is `wait_for`.

**Files:**
- Modify: migration, both `.sql` query files, `src/notyet/task.gleam`, `src/notyet/task/record.gleam`, `src/notyet/task/view.gleam`, `src/notyet/task/batch.gleam`, `CLAUDE.md`.
- Delete: `src/notyet/task/json_value.gleam`, `test/notyet/task/json_value_unit_test.gleam`.
- Modify tests: `decoder_unit_test.gleam`, `view_unit_test.gleam`, `handler_test.gleam`, `sql_integration_test.gleam`, `batch_test.gleam`, `router_integration_test.gleam`, `test_helper.gleam` (drop `data`/`activity` usage; `for`→`wait_for`).

- [ ] **Step 1: Rewrite the migration (drop `data`/`activity`/activity-index, rename `for_duration`→`wait_for`)**

`priv/migrations/20260521004749-create_tasks.sql`:

```sql
--- migration:up
CREATE TABLE tasks (
    id              UUID PRIMARY KEY,
    idempotency_key TEXT NOT NULL,
    wait_for        TEXT NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting')),
    created_at      TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX tasks_idempotency_key_idx ON tasks (idempotency_key);

--- migration:down
DROP TABLE tasks;

--- migration:end
```

- [ ] **Step 2: Rewrite both SQL query files**

`src/notyet/task/sql/insert_tasks.sql`:

```sql
INSERT INTO tasks (id, idempotency_key, wait_for, wait_until, created_at)
SELECT i::uuid, k, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[])
  AS t(i, k, f, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

`src/notyet/task/sql/get_task_by_idempotency_key.sql`:

```sql
SELECT
  id::text,
  idempotency_key,
  status,
  wait_for,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at
FROM tasks
WHERE idempotency_key = $1;
```

- [ ] **Step 3: Reset DB, migrate, regenerate squirrel**

```bash
docker compose down -v
```
```bash
make db-up
```
```bash
make migrate
```
```bash
make sqlgen
```
Expected: `GetTaskByIdempotencyKeyRow` now has fields `id, idempotency_key, status, wait_for, wait_until, created_at` (no `activity`/`data`); `insert_tasks` takes 5 list args.

- [ ] **Step 4: Delete the `json_value` module and its test**

```bash
git rm src/notyet/task/json_value.gleam
```
```bash
git rm test/notyet/task/json_value_unit_test.gleam
```

- [ ] **Step 5: Update `src/notyet/task/record.gleam`**

```gleam
import gleam/time/timestamp.{type Timestamp}
import youid/uuid.{type Uuid}

/// A fully-formed task ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. Fire-and-forget: nothing
/// is returned to the caller — the 202 is an enqueue ack, not a persisted row.
pub type TaskRecord {
  TaskRecord(
    id: Uuid,
    idempotency_key: String,
    wait_for: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
```

- [ ] **Step 6: Update `src/notyet/task/view.gleam`**

```gleam
import gleam/json
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import notyet/task/status.{type Status}
import youid/uuid.{type Uuid}

/// The read-back shape of a task. Pure: no `sql`/`pog` dependency, so `encode`
/// is unit-testable without a database. The handler maps a persisted row into
/// this before encoding.
pub type Task {
  Task(
    id: Uuid,
    idempotency_key: String,
    status: Status,
    wait_for: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}

/// Serialize a `Task` to the `200` response body. Timestamps are RFC3339, UTC.
pub fn encode(task: Task) -> json.Json {
  json.object([
    #("id", json.string(uuid.to_string(task.id))),
    #("idempotency_key", json.string(task.idempotency_key)),
    #("status", json.string(status.to_string(task.status))),
    #("wait_for", json.string(task.wait_for)),
    #("wait_until", json.string(rfc3339(task.wait_until))),
    #("created_at", json.string(rfc3339(task.created_at))),
  ])
}

fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
```

- [ ] **Step 7: Update `src/notyet/task/batch.gleam` (`do_insert` + drop `json_value`)**

Remove the `import gleam/json` and `import notyet/task/json_value` lines (no longer used), and remove the `data_string` helper. Replace `do_insert` with:

```gleam
fn do_insert(
  db: pog.Connection,
  records: List(TaskRecord),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let keys = list.map(records, fn(r) { r.idempotency_key })
  let fors = list.map(records, fn(r) { r.wait_for })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_tasks(db, ids, keys, fors, untils, createds)
}
```

(Keep `import gleam/json` only if still used elsewhere in the file — after removing `data_string` it is not; remove it. `rfc3339` and the other imports stay.)

- [ ] **Step 8: Update `src/notyet/task.gleam` (decoder, request type, handler, row mapping)**

Remove `import notyet/task/json_value`, `import gleam/option.{...}`, and the `activity_decoder`/`decode_data` functions. New relevant pieces:

```gleam
pub type TaskRequest {
  TaskRequest(duration: Duration, raw_wait_for: String)
}

pub fn task_decoder() -> decode.Decoder(TaskRequest) {
  use parsed <- decode.field("wait_for", for_decoder())
  decode.success(TaskRequest(duration: parsed.0, raw_wait_for: parsed.1))
}
```

`for_decoder` is unchanged (still parses the duration string; it just reads the `"wait_for"` field now via `task_decoder`). In `create_with_key`, build the record without `activity`/`data`:

```gleam
fn create_with_key(req: Request, ctx: Context, key: String) -> Response {
  use body <- wisp.require_json(req)
  case decode.run(body, task_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(tr) -> {
      let now = timestamp.system_time()
      let row =
        record.TaskRecord(
          id: uuid.v4(),
          idempotency_key: key,
          wait_for: tr.raw_wait_for,
          wait_until: timestamp.add(now, tr.duration),
          created_at: now,
        )
      case batch.enqueue(ctx.batch, row, ctx.enqueue_timeout_ms) {
        Ok(_) ->
          json.object([#("status", json.string(status.to_string(status.Accepted)))])
          |> json.to_string
          |> wisp.json_response(202)
        Error(_) ->
          wisp.response(429)
          |> wisp.set_header("retry-after", "1")
      }
    }
  }
}
```

Update `row_to_task` (no `activity`/`data`):

```gleam
fn row_to_task(row: sql.GetTaskByIdempotencyKeyRow) -> view.Task {
  let assert Ok(id) = uuid.from_string(row.id)
  let assert Ok(task_status) = status.from_string(row.status)
  let assert Ok(wait_until) = timestamp.parse_rfc3339(row.wait_until)
  let assert Ok(created_at) = timestamp.parse_rfc3339(row.created_at)
  view.Task(
    id: id,
    idempotency_key: row.idempotency_key,
    status: task_status,
    wait_for: row.wait_for,
    wait_until: wait_until,
    created_at: created_at,
  )
}
```

`parse_uuid_v4` stays (validates the `Idempotency-Key`). `create` and `read` keep their structure; `read_by_key` keeps `row |> row_to_task |> view.encode`.

- [ ] **Step 9: Update tests**

In all `test/notyet/task/*` and `test/notyet/router_integration_test.gleam` and `test/test_helper.gleam`:
- Drop every `activity` and `data` field from request bodies, `TaskRecord` constructions, and `view.Task`/`Task` constructions.
- Rename the JSON body key `"for"` → `"wait_for"` and any expected response key `"for"` → `"wait_for"`.
- Drop assertions on `activity`/`data` in expected responses.
- Update `TaskRecord(...)` calls to the new 5-field shape (`id`, `idempotency_key`, `wait_for`, `wait_until`, `created_at`).
- Update `view.Task(...)` calls to the new 6-field shape.
- Remove any `import notyet/task/json_value`.
- `decoder_unit_test`: remove cases asserting `activity`/`data` decoding; keep `wait_for` (duration) decode cases, now keyed `"wait_for"`.
- `view_unit_test`: assert the new flat body (no `data`).

- [ ] **Step 10: Build, test, commit**

```bash
make build
```
```bash
make test
```
Expected: green.
```bash
git add -A
```
```bash
git commit -m "refactor(task): drop data/activity, rename for to wait_for"
```

---

## Task 3: Add required `destination` (http/https URL)

New validated field. Body becomes `{"wait_for": <duration>, "destination": <http(s) url>}`; the response includes `destination`. TDD: validation tests first.

**Files:**
- Modify: migration, both `.sql` files, `src/notyet/task.gleam`, `src/notyet/task/record.gleam`, `src/notyet/task/view.gleam`, `src/notyet/task/batch.gleam`, `CLAUDE.md`.
- Modify tests: `decoder_unit_test.gleam` (new `destination` cases), `view_unit_test.gleam`, `handler_test.gleam`, `sql_integration_test.gleam`, `batch_test.gleam`, `router_integration_test.gleam`, `test_helper.gleam`.

- [ ] **Step 1: Write failing tests for `parse_http_url` / `destination_decoder`**

Add to `test/notyet/task/decoder_unit_test.gleam` (these reference the not-yet-exported `task.task_decoder` running over a body with `destination`; use the existing decoder-test style in that file). Example cases — adapt to the file's existing helpers:

```gleam
import gleam/dynamic/decode
import gleam/json
import gleeunit/should
import notyet/task

fn run(body: String) -> Result(task.TaskRequest, List(decode.DecodeError)) {
  let assert Ok(dyn) = json.parse(body, decode.dynamic)
  decode.run(dyn, task.task_decoder())
}

pub fn destination_valid_http_test() {
  run("{\"wait_for\":\"5 minutes\",\"destination\":\"http://example.com/cb\"}")
  |> should.be_ok
}

pub fn destination_valid_https_test() {
  run("{\"wait_for\":\"5 minutes\",\"destination\":\"https://example.com/cb\"}")
  |> should.be_ok
}

pub fn destination_rejects_non_http_scheme_test() {
  run("{\"wait_for\":\"5 minutes\",\"destination\":\"ftp://example.com\"}")
  |> should.be_error
}

pub fn destination_rejects_missing_host_test() {
  run("{\"wait_for\":\"5 minutes\",\"destination\":\"http:///path\"}")
  |> should.be_error
}

pub fn destination_rejects_garbage_test() {
  run("{\"wait_for\":\"5 minutes\",\"destination\":\"not a url\"}")
  |> should.be_error
}

pub fn destination_required_test() {
  run("{\"wait_for\":\"5 minutes\"}")
  |> should.be_error
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```
Expected: FAIL — `task_decoder` has no `destination` field, and `TaskRequest` has no `destination`, so these cases compile-error or fail.

- [ ] **Step 3: Add `parse_http_url` + `destination_decoder` and extend `TaskRequest`/`task_decoder` in `src/notyet/task.gleam`**

Add `import gleam/uri` and `import gleam/option.{Some}`. Then:

```gleam
pub type TaskRequest {
  TaskRequest(duration: Duration, raw_wait_for: String, destination: String)
}

/// Validate a destination as an http/https URL: parseable, scheme http|https,
/// non-empty host. Stores the raw string (no normalization).
fn parse_http_url(s: String) -> Result(String, Nil) {
  case uri.parse(s) {
    Ok(parsed) ->
      case parsed.scheme, parsed.host {
        Some("http"), Some(host) | Some("https"), Some(host) ->
          case host {
            "" -> Error(Nil)
            _ -> Ok(s)
          }
        _, _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn destination_decoder() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case parse_http_url(s) {
    Ok(url) -> decode.success(url)
    Error(_) -> decode.failure("", "destination must be an http(s) URL")
  }
}

pub fn task_decoder() -> decode.Decoder(TaskRequest) {
  use parsed <- decode.field("wait_for", for_decoder())
  use destination <- decode.field("destination", destination_decoder())
  decode.success(TaskRequest(
    duration: parsed.0,
    raw_wait_for: parsed.1,
    destination: destination,
  ))
}
```

- [ ] **Step 4: Run the decoder tests to verify they pass**

```bash
make test
```
Expected: the Step 1 cases PASS. (Other tests that build `TaskRecord`/`view.Task` without `destination` will now fail to compile — fixed in the next steps; that is expected mid-task.)

- [ ] **Step 5: Thread `destination` through record, handler, view, batch**

`src/notyet/task/record.gleam` — add field:

```gleam
pub type TaskRecord {
  TaskRecord(
    id: Uuid,
    idempotency_key: String,
    wait_for: String,
    destination: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
```

`src/notyet/task.gleam` `create_with_key` — set `destination: tr.destination` in the record:

```gleam
      let row =
        record.TaskRecord(
          id: uuid.v4(),
          idempotency_key: key,
          wait_for: tr.raw_wait_for,
          destination: tr.destination,
          wait_until: timestamp.add(now, tr.duration),
          created_at: now,
        )
```

`src/notyet/task.gleam` `row_to_task` — add `destination: row.destination,` to the `view.Task(...)`.

`src/notyet/task/view.gleam` — add `destination: String` to `Task` and `#("destination", json.string(task.destination))` to `encode` (place it after `created_at`).

`src/notyet/task/batch.gleam` `do_insert` — add the destinations list and pass it:

```gleam
fn do_insert(
  db: pog.Connection,
  records: List(TaskRecord),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let keys = list.map(records, fn(r) { r.idempotency_key })
  let fors = list.map(records, fn(r) { r.wait_for })
  let dests = list.map(records, fn(r) { r.destination })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_tasks(db, ids, keys, fors, dests, untils, createds)
}
```

- [ ] **Step 6: Add `destination` to the migration + SQL, reset, regen**

`priv/migrations/20260521004749-create_tasks.sql` — add the column (after `wait_for`):

```sql
--- migration:up
CREATE TABLE tasks (
    id              UUID PRIMARY KEY,
    idempotency_key TEXT NOT NULL,
    wait_for        TEXT NOT NULL,
    destination     TEXT NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting')),
    created_at      TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX tasks_idempotency_key_idx ON tasks (idempotency_key);

--- migration:down
DROP TABLE tasks;

--- migration:end
```

`src/notyet/task/sql/insert_tasks.sql`:

```sql
INSERT INTO tasks (id, idempotency_key, wait_for, destination, wait_until, created_at)
SELECT i::uuid, k, f, dest, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
  AS t(i, k, f, dest, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

`src/notyet/task/sql/get_task_by_idempotency_key.sql`:

```sql
SELECT
  id::text,
  idempotency_key,
  status,
  wait_for,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
  destination
FROM tasks
WHERE idempotency_key = $1;
```

Then:
```bash
docker compose down -v
```
```bash
make db-up
```
```bash
make migrate
```
```bash
make sqlgen
```
Expected: `insert_tasks` takes 6 list args; `GetTaskByIdempotencyKeyRow` gains `destination: String`.

- [ ] **Step 7: Update the remaining tests for `destination`**

- `view_unit_test.gleam`: add `destination` to `view.Task(...)` and assert `"destination"` in the encoded body.
- `handler_test.gleam`, `router_integration_test.gleam`: add `"destination"` to POST bodies; assert it round-trips on GET; add a `422` case for an invalid `destination` (e.g. `"ftp://x"`), and (router-level) confirm missing `destination` → `422`.
- `sql_integration_test.gleam`, `batch_test.gleam`, `test_helper.gleam`: add `destination` to every `TaskRecord(...)` construction (the 6-field shape).

- [ ] **Step 8: Build, test, commit**

```bash
make build
```
```bash
make test
```
Expected: green.
```bash
git add -A
```
```bash
git commit -m "feat(task): add required destination URL field"
```

- [ ] **Step 9: Update `CLAUDE.md` contract docs**

Update the `POST /tasks` / `GET /tasks/{key}` contract paragraphs to the final shape: body `{"wait_for", "destination"}`, response `{"id","idempotency_key","status","wait_for","wait_until","created_at","destination"}`, `destination` validated as http/https URL (`422` otherwise), no `data`/`activity`. Remove the duration-grammar references to the old `for` field name (now `wait_for`). Commit:

```bash
git add CLAUDE.md
```
```bash
git commit -m "docs: update task contract for wait_for/destination"
```

---

## Self-review notes

- **Spec coverage:** rename (T1), drop `data` (T2), drop `activity` (T2), `for`→`wait_for` (T2), single migration (rewritten each task; final in T3), `destination` http/https required (T3), env `WAIT_*`→`TASK_*` (T1), route `/tasks` plural (T1), delete `json_value` (T2). All covered.
- **Type consistency:** `TaskRequest` (duration, raw_wait_for, destination), `TaskRecord` (id, idempotency_key, wait_for, destination, wait_until, created_at), `view.Task` (id, idempotency_key, status, wait_for, wait_until, created_at, destination), `insert_tasks` 6 list args, `GetTaskByIdempotencyKeyRow` 7 fields — consistent across T2→T3.
- **DB resets** intentionally repeated (single disposable dev DB; rewriting an applied migration requires a volume drop).
