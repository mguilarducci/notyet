# Task Lifecycle Data/Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the task lifecycle into `pending → delivering → delivered | failed`, add an internal `visible_at` scheduler column, and update the API contract — laying groundwork for a future delivery worker without building the worker.

**Architecture:** A forward `ALTER` migration swaps the `status` CHECK domain and adds `visible_at` (initialized to `wait_until`). The Gleam `Status` enum, the `TaskRecord`, the batch insert path, and the squirrel-generated SQL are updated to carry `visible_at` and the new states. Because Gleam compiles the whole program and squirrel introspects the live DB, the enum change, the insert-arity change, and the migration are mutually dependent and land as one green commit.

**Tech Stack:** Gleam, wisp/mist, pog (Postgres), squirrel (typed SQL codegen), cigogne (migrations), gleeunit. DB-backed tests require Postgres up + migrated.

---

## File Structure

**Migration (new):**
- `priv/migrations/<timestamp>-task_lifecycle_states.sql` — ALTER `tasks`: new `status` CHECK domain (`pending|delivering|delivered|failed`), migrate `accepted→pending`, add `visible_at TIMESTAMPTZ NOT NULL`, add index `(status, visible_at)`.

**Source (modified):**
- `src/notyet/task/status.gleam` — replace the `Status` enum + `to_string`/`from_string`.
- `src/notyet/task/record.gleam` — add `visible_at` to `TaskRecord`.
- `src/notyet/task.gleam` — set `visible_at` on the record; `202` body uses `Pending`.
- `src/notyet/task/batch.gleam` — `do_insert` maps `visible_at`, calls the 7-arg `insert_tasks`.
- `src/notyet/task/sql/insert_tasks.sql` — add the `visible_at` column + param.
- `src/notyet/task/sql.gleam` — **regenerated** by `make sqlgen` (never hand-edited).

**Tests (modified):**
- `test/notyet/task/status_unit_test.gleam` — new state values.
- `test/notyet/task/view_unit_test.gleam` — new state values.
- `test/notyet/task/handler_test.gleam` — `202`/`GET` status `pending`; `seed` passes `visible_at`.
- `test/notyet/task/sql_integration_test.gleam` — every `insert_tasks` call passes `visible_at`; row status `pending`.
- `test/notyet/router_integration_test.gleam` — `202` status `pending`; insert passes `visible_at`.

**Docs (modified):**
- `CLAUDE.md` — status domain + `visible_at` in the architecture/contract sections.

---

## Prerequisites

Postgres must be up and the current schema migrated before starting:

- [ ] **Run:** `make db-up`
- [ ] **Run:** `make migrate`

---

## Task 1: Lifecycle states, `visible_at` column, and contract

This is one coherent change reaching a single green commit. Apply the steps in order; the suite only compiles once every step is done.

**Files:**
- Create: `priv/migrations/<timestamp>-task_lifecycle_states.sql`
- Modify: `src/notyet/task/status.gleam`
- Modify: `src/notyet/task/record.gleam`
- Modify: `src/notyet/task.gleam`
- Modify: `src/notyet/task/batch.gleam`
- Modify: `src/notyet/task/sql/insert_tasks.sql`
- Regenerate: `src/notyet/task/sql.gleam`
- Modify (tests): `status_unit_test.gleam`, `view_unit_test.gleam`, `handler_test.gleam`, `sql_integration_test.gleam`, `router_integration_test.gleam`

---

- [ ] **Step 1: Scaffold the migration**

Run: `make migrate-new NAME=task_lifecycle_states`
Expected: a new file `priv/migrations/<timestamp>-task_lifecycle_states.sql` is created with an empty `up`/`down`/`end` skeleton.

- [ ] **Step 2: Write the migration SQL**

Replace the scaffolded file's contents with:

```sql
--- migration:up
ALTER TABLE tasks DROP CONSTRAINT tasks_status_check;
UPDATE tasks SET status = 'pending' WHERE status = 'accepted';
ALTER TABLE tasks
  ADD CONSTRAINT tasks_status_check
  CHECK (status IN ('pending', 'delivering', 'delivered', 'failed'));
ALTER TABLE tasks ALTER COLUMN status SET DEFAULT 'pending';

ALTER TABLE tasks ADD COLUMN visible_at TIMESTAMPTZ;
UPDATE tasks SET visible_at = wait_until;
ALTER TABLE tasks ALTER COLUMN visible_at SET NOT NULL;

CREATE INDEX tasks_status_visible_at_idx ON tasks (status, visible_at);

--- migration:down
DROP INDEX tasks_status_visible_at_idx;
ALTER TABLE tasks DROP COLUMN visible_at;
ALTER TABLE tasks DROP CONSTRAINT tasks_status_check;
UPDATE tasks SET status = 'accepted' WHERE status = 'pending';
ALTER TABLE tasks
  ADD CONSTRAINT tasks_status_check
  CHECK (status IN ('accepted', 'waiting'));
ALTER TABLE tasks ALTER COLUMN status SET DEFAULT 'accepted';

--- migration:end
```

Note: the inline CHECK from the create migration is auto-named `tasks_status_check` (Postgres `<table>_<column>_check`). If `DROP CONSTRAINT tasks_status_check` errors with "constraint does not exist", inspect the real name and fix the migration:

Run: `docker compose exec -T postgres psql "$DATABASE_URL" -c '\d tasks'`
(The `down` only handles `pending` because no worker produces other states yet.)

- [ ] **Step 3: Apply the migration**

Run: `make migrate`
Expected: cigogne applies `task_lifecycle_states` with no error.

- [ ] **Step 4: Verify the schema changed**

Run: `docker compose exec -T postgres psql "$DATABASE_URL" -c '\d tasks'`
Expected: a `visible_at | timestamp with time zone | not null` column, an index `tasks_status_visible_at_idx` on `(status, visible_at)`, and the `tasks_status_check` listing `'pending','delivering','delivered','failed'`.

- [ ] **Step 5: Update the insert SQL to carry `visible_at`**

Replace `src/notyet/task/sql/insert_tasks.sql` with:

```sql
INSERT INTO tasks (id, idempotency_key, wait_for, destination, visible_at, wait_until, created_at)
SELECT i::uuid, k, f, dest, v::timestamptz, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, k, f, dest, v, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

(`visible_at` is `$5`; `wait_until` shifts to `$6`, `created_at` to `$7`.)

- [ ] **Step 6: Regenerate the typed SQL module**

Run: `make sqlgen`
Expected: `src/notyet/task/sql.gleam` now has `insert_tasks(db, arg_1 .. arg_7)` (seven `List(String)` params). At this point `gleam build` will FAIL — `batch.do_insert` still calls it with six args. That is expected; the next steps fix every call site.

- [ ] **Step 7: Rewrite the `Status` enum**

Replace `src/notyet/task/status.gleam` with:

```gleam
/// Lifecycle state of a task. `Pending` is the initial state set at creation
/// (the row's `visible_at` is still in the future). The remaining states are
/// produced by the delivery worker (later phase): `Delivering` while the
/// `destination` call is in flight, then the terminal `Delivered` (HTTP 2xx) or
/// `Failed`. Nothing transitions out of `Pending` yet (out of scope).
pub type Status {
  Pending
  Delivering
  Delivered
  Failed
}

pub fn to_string(status: Status) -> String {
  case status {
    Pending -> "pending"
    Delivering -> "delivering"
    Delivered -> "delivered"
    Failed -> "failed"
  }
}

pub fn from_string(value: String) -> Result(Status, Nil) {
  case value {
    "pending" -> Ok(Pending)
    "delivering" -> Ok(Delivering)
    "delivered" -> Ok(Delivered)
    "failed" -> Ok(Failed)
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 8: Add `visible_at` to `TaskRecord`**

Replace `src/notyet/task/record.gleam` with:

```gleam
import gleam/time/timestamp.{type Timestamp}
import youid/uuid.{type Uuid}

/// A fully-formed task ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. Fire-and-forget: nothing
/// is returned to the caller — the 202 is an enqueue ack, not a persisted row.
/// `visible_at` is the scheduler column (when the row becomes eligible to run);
/// it equals `wait_until` at creation. `wait_until` is the immutable intent.
pub type TaskRecord {
  TaskRecord(
    id: Uuid,
    idempotency_key: String,
    wait_for: String,
    destination: String,
    visible_at: Timestamp,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
```

- [ ] **Step 9: Set `visible_at` on the record and return `pending` from `POST`**

In `src/notyet/task.gleam`, replace the body-building block in `create_with_key` (currently lines ~100-124) with:

```gleam
    Ok(tr) -> {
      let now = timestamp.system_time()
      let wait_until = timestamp.add(now, tr.duration)
      let row =
        record.TaskRecord(
          id: uuid.v4(),
          idempotency_key: key,
          wait_for: tr.raw_wait_for,
          destination: tr.destination,
          visible_at: wait_until,
          wait_until: wait_until,
          created_at: now,
        )
      case batch.enqueue(ctx.batch, row, ctx.enqueue_timeout_ms) {
        Ok(_) ->
          json.object([#("status", json.string(status.to_string(status.Pending)))])
          |> json.to_string
          |> wisp.json_response(202)
        // Shed: real client demand exceeded admission. 429 + Retry-After tells
        // the client to back off; the Idempotency-Key makes the retry safe (it
        // never creates a second row).
        Error(_) ->
          wisp.response(429)
          |> wisp.set_header("retry-after", "1")
      }
    }
```

- [ ] **Step 10: Update `do_insert` to map and pass `visible_at`**

In `src/notyet/task/batch.gleam`, replace the `do_insert` function (currently lines ~239-250) with:

```gleam
fn do_insert(
  db: pog.Connection,
  records: List(TaskRecord),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let keys = list.map(records, fn(r) { r.idempotency_key })
  let wait_fors = list.map(records, fn(r) { r.wait_for })
  let dests = list.map(records, fn(r) { r.destination })
  let visibles = list.map(records, fn(r) { rfc3339(r.visible_at) })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_tasks(db, ids, keys, wait_fors, dests, visibles, untils, createds)
}
```

- [ ] **Step 11: Update `status_unit_test`**

Replace `test/notyet/task/status_unit_test.gleam` with:

```gleam
import notyet/task/status

pub fn to_string_pending_test() {
  assert status.to_string(status.Pending) == "pending"
}

pub fn to_string_delivering_test() {
  assert status.to_string(status.Delivering) == "delivering"
}

pub fn to_string_delivered_test() {
  assert status.to_string(status.Delivered) == "delivered"
}

pub fn to_string_failed_test() {
  assert status.to_string(status.Failed) == "failed"
}

pub fn from_string_pending_test() {
  assert status.from_string("pending") == Ok(status.Pending)
}

pub fn from_string_delivering_test() {
  assert status.from_string("delivering") == Ok(status.Delivering)
}

pub fn from_string_delivered_test() {
  assert status.from_string("delivered") == Ok(status.Delivered)
}

pub fn from_string_failed_test() {
  assert status.from_string("failed") == Ok(status.Failed)
}

pub fn from_string_unknown_test() {
  assert status.from_string("bogus") == Error(Nil)
}

pub fn round_trip_pending_test() {
  assert status.from_string(status.to_string(status.Pending))
    == Ok(status.Pending)
}

pub fn round_trip_delivered_test() {
  assert status.from_string(status.to_string(status.Delivered))
    == Ok(status.Delivered)
}
```

- [ ] **Step 12: Update `view_unit_test`**

In `test/notyet/task/view_unit_test.gleam`:

Change the `sample()` status field (line ~15) from `status: status.Accepted,` to:

```gleam
    status: status.Pending,
```

Change the status assertion (line ~27) from `== "accepted"` to:

```gleam
  assert test_helper.json_field(body, "status") == "pending"
```

Replace the `encode_status_waiting_test` function (lines ~42-46) with:

```gleam
pub fn encode_status_delivered_test() {
  let delivered = view.Task(..sample(), status: status.Delivered)
  let body = json.to_string(view.encode(delivered))
  assert test_helper.json_field(body, "status") == "delivered"
}
```

- [ ] **Step 13: Update `handler_test`**

In `test/notyet/task/handler_test.gleam`:

Change the `202` body assertion in `create_accepts_and_persists_test` (line ~24) from `== "accepted"` to:

```gleam
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "pending"
```

Replace the `seed` helper (lines ~90-102) with the 7-arg insert (adds `visible_at` as the 5th list):

```gleam
fn seed(db, key) {
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [test_helper.v4],
      [key],
      ["5 minutes"],
      [dest],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  Nil
}
```

Change the GET status assertion in `read_returns_200_with_resource_test` (line ~113) from `== "accepted"` to:

```gleam
  assert test_helper.json_field(body, "status") == "pending"
```

- [ ] **Step 14: Update `sql_integration_test`**

In `test/notyet/task/sql_integration_test.gleam`, add `visible_at` (use the existing `ts`) as the 5th argument to every `insert_tasks` call, and change the row-status assertion. Replace the call sites as follows.

`insert_two_rows_test` (lines ~16-25):

```gleam
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(
      db,
      [v4_a, v4_b],
      ["k-a", "k-b"],
      ["5 minutes", "1 hour"],
      [dest, dest],
      [ts, ts],
      [ts, ts],
      [ts, ts],
    )
```

`insert_single_row_test` (line ~33):

```gleam
    sql.insert_tasks(db, [v4_a], ["k-a"], ["1 day"], [dest], [ts], [ts], [ts])
```

`empty_list_no_op_test` (line ~39):

```gleam
    sql.insert_tasks(db, [], [], [], [], [], [], [])
```

`get_by_key_returns_inserted_row_test` (lines ~47-56):

```gleam
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a],
      ["look-me-up"],
      ["5 minutes"],
      [dest],
      [ts],
      [ts],
      [ts],
    )
```

In the same test, change the status assertion (line ~62) from `== "accepted"` to:

```gleam
  assert row.status == "pending"
```

`same_key_dedups_to_one_row_test` (lines ~83-86):

```gleam
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_a], ["key-1"], ["5 minutes"], [dest], [ts], [ts], [ts])
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_b], ["key-1"], ["1 hour"], [dest], [ts], [ts], [ts])
```

`intra_batch_same_key_one_row_test` (lines ~94-104):

```gleam
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a, v4_b],
      ["same", "same"],
      ["1 day", "1 day"],
      [dest, dest],
      [ts, ts],
      [ts, ts],
      [ts, ts],
    )
```

`distinct_keys_two_rows_test` (lines ~109-112):

```gleam
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_a], ["key-1"], ["1 day"], [dest], [ts], [ts], [ts])
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_b], ["key-2"], ["1 day"], [dest], [ts], [ts], [ts])
```

- [ ] **Step 15: Update `router_integration_test`**

In `test/notyet/router_integration_test.gleam`:

Replace the `insert_tasks` call in `get_task_returns_200_test` (lines ~30-39) with the 7-arg form:

```gleam
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [test_helper.v4],
      [test_helper.v4],
      ["5 minutes"],
      [dest],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
```

Change the `202` body assertion in `post_task_happy_path_test` (line ~76) from `== "accepted"` to:

```gleam
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "pending"
```

- [ ] **Step 16: Update the `rec()` test helper in `batch_test`**

In `test/notyet/task/batch_test.gleam`, replace the `rec()` builder (lines ~10-19) to include `visible_at`:

```gleam
fn rec() -> record.TaskRecord {
  record.TaskRecord(
    id: uuid.v4(),
    idempotency_key: uuid.v4_string(),
    wait_for: "5 minutes",
    destination: "https://example.com/cb",
    visible_at: timestamp.system_time(),
    wait_until: timestamp.system_time(),
    created_at: timestamp.system_time(),
  )
}
```

- [ ] **Step 17: Run the full suite**

Run: `make test`
Expected: PASS — the project compiles and every test is green. If `gleam build` reports an arity error on `insert_tasks`, a call site from Steps 13-15 still has six args; fix it.

- [ ] **Step 18: Commit**

```bash
git add priv/migrations src/notyet/task/status.gleam src/notyet/task/record.gleam src/notyet/task.gleam src/notyet/task/batch.gleam src/notyet/task/sql/insert_tasks.sql src/notyet/task/sql.gleam test/notyet/task/status_unit_test.gleam test/notyet/task/view_unit_test.gleam test/notyet/task/handler_test.gleam test/notyet/task/sql_integration_test.gleam test/notyet/router_integration_test.gleam test/notyet/task/batch_test.gleam
git commit -m "feat(task): add pending/delivering/delivered/failed lifecycle and visible_at column"
```

---

## Task 2: Coverage check and docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the coverage suite**

Run: `./bin/coverage`
Expected: the suite passes and prints a per-module + total summary. No new uncovered lines/clauses in `status.gleam`, `record.gleam`, `task.gleam`, or `batch.gleam` beyond the pre-existing irreducible `main/0` glue. If a new gap appears (e.g. an untested `Status` clause), add a test for it and re-run — do not exclude code.

- [ ] **Step 2: Update `CLAUDE.md` status references**

In `CLAUDE.md`, update the architecture/contract prose so it matches the new model. Make these substitutions in the relevant sentences:

- The `task/status.gleam` description: change "`Status` state machine (`Accepted`/`Waiting`) with `to_string`/`from_string`. `Accepted` is the initial state; `Waiting` is reserved (no transitions yet)." to "`Status` state machine (`Pending`/`Delivering`/`Delivered`/`Failed`) with `to_string`/`from_string`. `Pending` is the initial state; the other states are produced by the (not-yet-built) delivery worker."
- The `record.gleam` description: add `visible_at` to the listed `TaskRecord` fields ("`id`, `idempotency_key`, `wait_for`, `destination`, `visible_at`, `wait_until`, `created_at`").
- The `POST /tasks` contract: change `**202 {"status": "accepted"}**` to `**202 {"status": "pending"}**`.
- The `POST /tasks` contract: change the `status` state-machine sentence to "`status` is seeded at `pending` (the `tasks.status` column defaults to `'pending'` with `CHECK (status IN ('pending','delivering','delivered','failed'))`). `visible_at` (the scheduler column, internal) is initialized to `wait_until`."
- The `GET /tasks/{key}` contract: leave the response field list as-is (`visible_at` is **not** exposed), but note `status` is now one of `pending|delivering|delivered|failed`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update task lifecycle states and visible_at in CLAUDE.md"
```

---

## Self-Review

**Spec coverage:**
- States `pending/delivering/delivered/failed` → Task 1 Step 7 (`status.gleam`), migration CHECK (Step 2).
- `visible_at` scheduler column, init = `wait_until`, internal → migration (Step 2), `record` (Step 8), `task.create` (Step 9), `do_insert` (Step 10), insert SQL (Step 5); not exposed in `GET` (view unchanged).
- ALTER migration (reversible), `accepted→pending`, index `(status, visible_at)` → Step 2.
- `POST` `202` body `{"status":"pending"}` → Step 9, asserted Steps 13/15.
- `GET` status domain change → asserted Steps 13/14.
- No `attempts`/`last_error`/`lease_expires_at`/retry/worker → none added (confirmed absent).

**Placeholder scan:** none — every code/SQL/command step shows full content.

**Type consistency:** `TaskRecord` gains `visible_at: Timestamp` (Step 8), constructed in Step 9, mapped in Step 10. `insert_tasks` is 7-arg everywhere after `make sqlgen` (Step 6); all call sites (Steps 10, 13, 14, 15) pass seven lists with `visible_at` as the 5th. `Status` constructors `Pending/Delivering/Delivered/Failed` used consistently in Steps 7, 9, 11, 12.
