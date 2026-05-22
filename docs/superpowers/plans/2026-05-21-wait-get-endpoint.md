# GET /wait/{key} Read Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `GET /wait/{key}` that returns a previously-accepted wait by its `Idempotency-Key`, returning the complete resource as JSON (`200`) or `404` when no row exists.

**Architecture:** A pure domain read-model (`view.Wait` + `view.encode`) decouples the JSON shape from the squirrel-generated SQL row. The handler is the persistence seam: it runs a new squirrel query against a `pog.Connection` newly threaded through `web.Context`, maps the row → `view.Wait`, and encodes. The read path never touches the write-behind coordinator, so a wait accepted (`202`) but not yet flushed reads as `404`.

**Tech Stack:** Gleam, wisp (routing/handlers), pog (Postgres), squirrel (typed queries), gleam_time (timestamps), youid (UUIDs), gleeunit + wisp/simulate (tests).

---

## Prerequisites (run once before testing)

The suite and `make sqlgen` need a live, migrated Postgres. Run these as **separate** commands (no compound shell anywhere in this repo):

```bash
make db-up
```
```bash
make migrate
```

`make test` runs the whole gleeunit suite (many tests hit the live DB), so keep Postgres up throughout.

---

## File Structure

- **Modify `src/notyet/web.gleam`** — add `db: pog.Connection` to `Context`.
- **Modify `src/notyet.gleam`** — pass the existing `db` handle into the `Context` constructor.
- **Modify `test/test_helper.gleam`** — add `db:` to the `writer_ctx` `Context` construction.
- **Create `src/notyet/wait/view.gleam`** — pure read-model type `Wait` + `encode`. No `sql`/`pog` import.
- **Create `test/notyet/wait/view_unit_test.gleam`** — unit tests for `encode` (no DB).
- **Create `src/notyet/wait/sql/get_wait_by_idempotency_key.sql`** — the SELECT; squirrel generates the typed function into `src/notyet/wait/sql.gleam`.
- **Modify `test/notyet/wait/sql_integration_test.gleam`** — add read-query tests.
- **Modify `src/notyet/wait.gleam`** — add the `read` handler + row→`Wait` mapping.
- **Modify `src/notyet/router.gleam`** — dispatch `["wait", key]`.
- **Modify `test/notyet/wait/handler_test.gleam`** — add `read` handler tests.
- **Modify `test/notyet/router_integration_test.gleam`** — add GET dispatch + 405 tests.
- **Modify `CLAUDE.md`** — document the new endpoint (it currently calls reading "a future endpoint").

---

## Task 1: Thread a DB connection through `Context`

The read path queries Postgres directly (the coordinator owns its own connection). Add a `db` field to `Context`, wire it from the existing named handle, and update the test constructor. Pure plumbing — no behavior change; the existing suite must still pass.

**Files:**
- Modify: `src/notyet/web.gleam`
- Modify: `src/notyet.gleam:54-55`
- Modify: `test/test_helper.gleam:93-103`

- [ ] **Step 1: Add `db` to the `Context` type**

Edit `src/notyet/web.gleam`. Add the `pog` import and the field:

```gleam
import gleam/erlang/process
import notyet/wait/batch
import pog
import wisp

pub type Context {
  Context(
    db: pog.Connection,
    batch: process.Subject(batch.Message),
    enqueue_timeout_ms: Int,
  )
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

- [ ] **Step 2: Pass `db` into the `Context` at boot**

Edit `src/notyet.gleam`. The handle `db` already exists (line 37). Update the constructor:

```gleam
  let batch_subject = process.named_subject(batch_name)
  let ctx =
    web.Context(
      db: db,
      batch: batch_subject,
      enqueue_timeout_ms: enqueue_timeout_ms,
    )
```

- [ ] **Step 3: Update the test `Context` constructor**

Edit `test/test_helper.gleam`. `writer_ctx` already receives `db`; add the field:

```gleam
pub fn writer_ctx(
  db: pog.Connection,
  max_size: Int,
  interval_ms: Int,
  max_in_flight: Int,
) -> web.Context {
  web.Context(
    db: db,
    batch: start_writer(db, max_size, interval_ms, max_in_flight),
    enqueue_timeout_ms: 1000,
  )
}
```

- [ ] **Step 4: Build and run the suite to confirm no regression**

Run: `make build`
Expected: compiles with no errors.

Run: `make test`
Expected: all existing tests pass (DB must be up + migrated).

- [ ] **Step 5: Commit**

```bash
git add src/notyet/web.gleam src/notyet.gleam test/test_helper.gleam
git commit -m "refactor(web): add db connection to Context for read path"
```

---

## Task 2: Read-model `view` module + encoder (TDD)

A pure module: the `Wait` type and a JSON encoder producing the `200` body. No DB dependency, so the encoder is fully unit-testable by constructing `Wait` directly.

**Files:**
- Create: `src/notyet/wait/view.gleam`
- Test: `test/notyet/wait/view_unit_test.gleam`

- [ ] **Step 1: Write the failing tests**

Create `test/notyet/wait/view_unit_test.gleam`:

```gleam
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import notyet/wait/json_value.{type JsonValue, JInt, JObject}
import notyet/wait/status
import notyet/wait/view
import test_helper
import youid/uuid

const id_str = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const activity_str = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

fn sample(data: option.Option(JsonValue)) -> view.Wait {
  let assert Ok(id) = uuid.from_string(id_str)
  let assert Ok(activity) = uuid.from_string(activity_str)
  view.Wait(
    id: id,
    activity: activity,
    idempotency_key: "k-1",
    status: status.Accepted,
    for_duration: "5 minutes",
    wait_until: timestamp.from_unix_seconds(1_000_000),
    created_at: timestamp.from_unix_seconds(900_000),
    data: data,
  )
}

pub fn encode_includes_core_fields_test() {
  let body = json.to_string(view.encode(sample(None)))
  assert test_helper.json_field(body, "id") == id_str
  assert test_helper.json_field(body, "activity") == activity_str
  assert test_helper.json_field(body, "idempotency_key") == "k-1"
  assert test_helper.json_field(body, "status") == "accepted"
  assert test_helper.json_field(body, "for") == "5 minutes"
}

pub fn encode_timestamps_are_rfc3339_utc_test() {
  let body = json.to_string(view.encode(sample(None)))
  let assert Ok(wu) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "wait_until"))
  assert wu == timestamp.from_unix_seconds(1_000_000)
  let assert Ok(ca) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "created_at"))
  assert ca == timestamp.from_unix_seconds(900_000)
}

pub fn encode_omits_data_when_none_test() {
  let body = json.to_string(view.encode(sample(None)))
  assert string.contains(body, "\"data\"") == False
}

pub fn encode_includes_data_object_when_present_test() {
  let data = JObject(dict.from_list([#("k", JInt(1))]))
  let body = json.to_string(view.encode(sample(Some(data))))
  let assert Ok(parsed) =
    json.parse(body, {
      use d <- decode.field("data", json_value.decoder())
      decode.success(d)
    })
  assert parsed == data
}

pub fn encode_status_waiting_test() {
  let waiting = view.Wait(..sample(None), status: status.Waiting)
  let body = json.to_string(view.encode(waiting))
  assert test_helper.json_field(body, "status") == "waiting"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test`
Expected: compile error — `notyet/wait/view` does not exist / `view.Wait` unknown.

- [ ] **Step 3: Implement the read-model**

Create `src/notyet/wait/view.gleam`:

```gleam
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import notyet/wait/status.{type Status}
import youid/uuid.{type Uuid}

/// The read-back shape of a wait. Pure: no `sql`/`pog` dependency, so `encode`
/// is unit-testable without a database. The handler maps a persisted row into
/// this before encoding.
pub type Wait {
  Wait(
    id: Uuid,
    activity: Uuid,
    idempotency_key: String,
    status: Status,
    for_duration: String,
    wait_until: Timestamp,
    created_at: Timestamp,
    data: Option(JsonValue),
  )
}

/// Serialize a `Wait` to the `200` response body. `data` is omitted entirely
/// when absent (symmetric with the optional `data` on write). Timestamps are
/// RFC3339, UTC.
pub fn encode(wait: Wait) -> json.Json {
  let base = [
    #("id", json.string(uuid.to_string(wait.id))),
    #("activity", json.string(uuid.to_string(wait.activity))),
    #("idempotency_key", json.string(wait.idempotency_key)),
    #("status", json.string(status.to_string(wait.status))),
    #("for", json.string(wait.for_duration)),
    #("wait_until", json.string(rfc3339(wait.wait_until))),
    #("created_at", json.string(rfc3339(wait.created_at))),
  ]
  let fields = case wait.data {
    Some(value) -> list.append(base, [#("data", json_value.encode(value))])
    None -> base
  }
  json.object(fields)
}

fn rfc3339(t: Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `make test`
Expected: the five `view_unit_test` tests pass; the rest of the suite stays green.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait/view.gleam test/notyet/wait/view_unit_test.gleam
git commit -m "feat(wait): add Wait read-model and JSON encoder"
```

---

## Task 3: `get_wait_by_idempotency_key` query (squirrel)

Author the SELECT, generate the typed function, and verify it against a live DB. UUIDs and `data` are cast to `text` so squirrel produces `String` fields (reusing `json_value` for `data` and validating UUIDs in the handler); timestamptz stays native so it decodes to `gleam/time/timestamp.Timestamp` for RFC3339 formatting.

**Files:**
- Create: `src/notyet/wait/sql/get_wait_by_idempotency_key.sql`
- Modify (generated, do not hand-edit): `src/notyet/wait/sql.gleam`
- Test: `test/notyet/wait/sql_integration_test.gleam`

- [ ] **Step 1: Write the SQL**

Create `src/notyet/wait/sql/get_wait_by_idempotency_key.sql`:

```sql
SELECT
  id::text,
  activity::text,
  idempotency_key,
  status,
  for_duration,
  wait_until,
  created_at,
  data::text
FROM waits
WHERE idempotency_key = $1;
```

- [ ] **Step 2: Generate the typed query module**

Run: `make sqlgen`
Expected: regenerates `src/notyet/wait/sql.gleam`, adding `get_wait_by_idempotency_key` and a `GetWaitByIdempotencyKeyRow` record. The generated function/row should look like:

```gleam
pub type GetWaitByIdempotencyKeyRow {
  GetWaitByIdempotencyKeyRow(
    id: String,
    activity: String,
    idempotency_key: String,
    status: String,
    for_duration: String,
    wait_until: timestamp.Timestamp,
    created_at: timestamp.Timestamp,
    data: option.Option(String),
  )
}

pub fn get_wait_by_idempotency_key(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(GetWaitByIdempotencyKeyRow), pog.QueryError)
```

If the generated field types differ from the above (e.g. squirrel maps `uuid`/`timestamptz` differently in this version), adjust the row→`Wait` mapping in Task 4 to match the actual generated types — keep the SQL casts as written. Do not hand-edit `sql.gleam`.

- [ ] **Step 3: Write the integration tests**

Add `import gleam/option` to the top of `test/notyet/wait/sql_integration_test.gleam` (it already imports `gleam/dynamic/decode`, `notyet/wait/sql`, `pog`, `test_helper`, and defines `v4_a`, `v4_b`, `ts`). Then add:

```gleam
pub fn get_by_key_returns_inserted_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(
      db,
      [v4_a],
      [v4_b],
      ["look-me-up"],
      ["{\"k\":1}"],
      ["5 minutes"],
      [ts],
      [ts],
    )
  let assert Ok(pog.Returned(count, [row])) =
    sql.get_wait_by_idempotency_key(db, "look-me-up")
  assert count == 1
  assert row.id == v4_a
  assert row.activity == v4_b
  assert row.idempotency_key == "look-me-up"
  assert row.status == "accepted"
  assert row.for_duration == "5 minutes"
  // Postgres re-serializes jsonb with a space after the colon: {"k":1} -> {"k": 1}.
  assert row.data == option.Some("{\"k\": 1}")
}

pub fn get_by_key_missing_returns_empty_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, rows)) =
    sql.get_wait_by_idempotency_key(db, "nope")
  assert count == 0
  assert rows == []
}

pub fn get_by_key_null_data_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["no-data"], [""], ["1 day"], [ts], [ts])
  let assert Ok(pog.Returned(_, [row])) =
    sql.get_wait_by_idempotency_key(db, "no-data")
  assert row.data == option.None
}
```

- [ ] **Step 4: Run the integration tests**

Run: `make test`
Expected: `get_by_key_returns_inserted_row_test`, `get_by_key_missing_returns_empty_test`, and `get_by_key_null_data_test` pass.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait/sql/get_wait_by_idempotency_key.sql src/notyet/wait/sql.gleam test/notyet/wait/sql_integration_test.gleam
git commit -m "feat(wait): add get_wait_by_idempotency_key query"
```

---

## Task 4: `read` handler + router wiring (TDD)

The handler runs the query, maps the row → `view.Wait` (the persistence seam: validate UUIDs, parse `data` text, lift `status`), encodes, and answers `200`/`404`. The router dispatches `["wait", key]` for `GET` and `405` otherwise.

**Files:**
- Modify: `src/notyet/wait.gleam`
- Modify: `src/notyet/router.gleam`
- Test: `test/notyet/wait/handler_test.gleam`
- Test: `test/notyet/router_integration_test.gleam`

- [ ] **Step 1: Write the failing handler tests**

Add to `test/notyet/wait/handler_test.gleam` (file imports `gleam/http`, `gleam/http/request`, `notyet/wait`, `test_helper`, `wisp/simulate`, and defines local `ctx`). Add `import notyet/wait/sql` at the top, then:

```gleam
fn seed(db, key) {
  let assert Ok(_) =
    sql.insert_waits(
      db,
      [test_helper.v4],
      [test_helper.v4],
      [key],
      ["{\"k\":1}"],
      ["5 minutes"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  Nil
}

pub fn read_returns_200_with_resource_test() {
  use db <- test_helper.with_db
  seed(db, "read-me")
  let response =
    simulate.request(http.Get, "/wait/read-me")
    |> wait.read(ctx(db), "read-me")
  assert response.status == 200
  let body = simulate.read_body(response)
  assert test_helper.json_field(body, "idempotency_key") == "read-me"
  assert test_helper.json_field(body, "status") == "accepted"
  assert test_helper.json_field(body, "for") == "5 minutes"
  assert test_helper.json_field(body, "activity") == test_helper.v4
}

pub fn read_missing_key_returns_404_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Get, "/wait/ghost")
    |> wait.read(ctx(db), "ghost")
  assert response.status == 404
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make test`
Expected: compile error — `wait.read` is not defined.

- [ ] **Step 3: Implement the `read` handler**

Edit `src/notyet/wait.gleam`. Update the `http` import to include `Get`, add `pog`, `view`, and the `sql` module imports, then add the handler and mapping. The new imports block:

```gleam
import gleam/http.{Get, Post}
```

Add alongside the existing imports:

```gleam
import notyet/wait/sql
import notyet/wait/view
import pog
```

Append the handler and helpers at the end of the module:

```gleam
pub fn read(req: Request, ctx: Context, key: String) -> Response {
  use <- wisp.require_method(req, Get)

  case sql.get_wait_by_idempotency_key(ctx.db, key) {
    Ok(pog.Returned(_, [row])) ->
      row
      |> row_to_wait
      |> view.encode
      |> json.to_string
      |> wisp.json_response(200)
    // idempotency_key is UNIQUE, so the result is 0 or 1 row.
    Ok(pog.Returned(_, _)) -> wisp.not_found()
    Error(_) -> wisp.internal_server_error()
  }
}

/// Map a persisted row into the read-model. The row is written only by this
/// service through a schema with a UNIQUE key, a status CHECK, and object-only
/// `data`, so the conversions are total against stored data — hence `let assert`.
fn row_to_wait(row: sql.GetWaitByIdempotencyKeyRow) -> view.Wait {
  let assert Ok(id) = uuid.from_string(row.id)
  let assert Ok(activity) = uuid.from_string(row.activity)
  let assert Ok(wait_status) = status.from_string(row.status)
  view.Wait(
    id: id,
    activity: activity,
    idempotency_key: row.idempotency_key,
    status: wait_status,
    for_duration: row.for_duration,
    wait_until: row.wait_until,
    created_at: row.created_at,
    data: decode_data(row.data),
  )
}

fn decode_data(text: Option(String)) -> Option(JsonValue) {
  case text {
    None -> None
    Some(s) -> {
      let assert Ok(value) = json.parse(s, json_value.decoder())
      Some(value)
    }
  }
}
```

- [ ] **Step 4: Run the handler tests**

Run: `make test`
Expected: `read_returns_200_with_resource_test` and `read_missing_key_returns_404_test` pass.

- [ ] **Step 5: Wire the router**

Edit `src/notyet/router.gleam`:

```gleam
import gleam/http.{Get, Post}
import notyet/wait
import notyet/web.{type Context}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req)

  case wisp.path_segments(req), req.method {
    ["wait"], Post -> wait.create(req, ctx)
    ["wait"], _ -> wisp.method_not_allowed([Post])
    ["wait", key], Get -> wait.read(req, ctx, key)
    ["wait", key], _ -> wisp.method_not_allowed([Get])
    _, _ -> wisp.not_found()
  }
}
```

- [ ] **Step 6: Write the router integration tests**

Add to `test/notyet/router_integration_test.gleam` (already imports `gleam/http`, `notyet/router`, `test_helper`, `wisp/simulate`). Add `import notyet/wait/sql` and `import wisp/simulate` is present; then:

```gleam
pub fn get_wait_returns_200_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let assert Ok(_) =
    sql.insert_waits(
      db,
      [test_helper.v4],
      [test_helper.v4],
      ["router-get"],
      [""],
      ["5 minutes"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  let response =
    simulate.request(http.Get, "/wait/router-get")
    |> router.handle_request(ctx)
  assert response.status == 200
  assert test_helper.json_field(simulate.read_body(response), "idempotency_key")
    == "router-get"
}

pub fn get_wait_missing_returns_404_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    simulate.request(http.Get, "/wait/missing")
    |> router.handle_request(ctx)
  assert response.status == 404
}

pub fn get_wait_wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Delete, "/wait/whatever")
    |> router.handle_request(dummy_ctx())
  assert response.status == 405
}
```

- [ ] **Step 7: Run the full suite**

Run: `make test`
Expected: all tests pass, including the new router tests.

- [ ] **Step 8: Commit**

```bash
git add src/notyet/wait.gleam src/notyet/router.gleam test/notyet/wait/handler_test.gleam test/notyet/router_integration_test.gleam
git commit -m "feat(wait): add GET /wait/{key} read endpoint"
```

---

## Task 5: Document the endpoint

`CLAUDE.md` currently describes reading a wait as "a future endpoint". Update it to reflect the shipped read path.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the contract description**

In `CLAUDE.md`, find the sentence:

> Reading a wait back (e.g. `GET /wait/{key}`) is a future endpoint.

Replace it with:

> `GET /wait/{key}` reads a wait back by its `Idempotency-Key`: **`200`** with the complete resource (`id`, `activity`, `idempotency_key`, `status`, `for`, `wait_until`, `created_at`, and `data` when present) when the row exists, or **`404`** when it does not. Because the write path is async, a `GET` issued right after a `202` may `404` until the row is flushed; the read path queries Postgres only and never the coordinator buffer. Wrong method on `["wait", key]` → `405`.

- [ ] **Step 2: Update the architecture notes for `wait.gleam` and `web.gleam`**

In the `src/notyet/wait.gleam` bullet, note it now also holds the `read` handler and the row→`view.Wait` mapping. In the `src/notyet/web.gleam` bullet, note `Context` now carries `db: pog.Connection` for the read path. Add a bullet for the new `src/notyet/wait/view.gleam` module (the pure read-model + encoder).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document GET /wait/{key} endpoint"
```

---

## Self-Review Notes

- **Spec coverage:** lookup by `idempotency_key` (Task 3 SQL `WHERE idempotency_key = $1`); complete-resource body (Task 2 `encode`); `404` on miss incl. async window (Task 4 `Ok(pog.Returned(_, _)) -> not_found`); `405` wrong method (Task 4 router + test); read-model isolation (`view.gleam` has no `sql`/`pog` import); `db` in `Context` (Task 1); no migration (none added); `data` omitted when null (Task 2 + Task 3 null test); RFC3339 UTC timestamps (Task 2). All covered.
- **Generated-code caveat:** Step 2 of Task 3 pins the expected squirrel output and instructs adjusting the Task 4 mapping if the local squirrel version emits different field types — the only point of genuine uncertainty.
- **Type consistency:** `view.Wait` fields match between `view.gleam` (Task 2), the `view_unit_test` constructor (Task 2), and `row_to_wait` (Task 4). `GetWaitByIdempotencyKeyRow` field names (`id`, `activity`, `idempotency_key`, `status`, `for_duration`, `wait_until`, `created_at`, `data`) match the `row.<field>` accesses in Tasks 3–4.
