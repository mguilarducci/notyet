# Design: task lifecycle states + data/contract restructure (delivery groundwork)

**Date:** 2026-05-22
**Status:** approved

## Goal

Restructure the task lifecycle state machine, schema, and API contract to lay the
groundwork for a future delivery worker — **without** building the worker in this
session. After this change the schema and contract carry the full lifecycle
vocabulary; the worker that produces the non-initial states comes in a later phase.

Grounded in a study of Temporal's internals (verified against the
`temporalio/temporal` source): readiness is a **computed query predicate**
(`visible_at <= now()`), not a stored "ready" state; a single scheduler column
(`visibility_timestamp`) drives both the initial wait and future retry backoff.

## Scope

**In scope (this session):**
- New `Status` enum and state machine: `pending → delivering → delivered | failed`.
- Schema migration: new `status` domain, new `visible_at` scheduler column, scan index.
- Contract change: `POST` `202` body, `GET` `status` value domain.
- `TaskRecord` + insert path carry `visible_at`.

**Out of scope (later phases):**
- The delivery worker (due-scan, claim, HTTP call to `destination`, terminal transitions).
- `lease_expires_at` / crash-recovery reclaim (worker mechanic).
- Retry: `attempts`, `last_error`, backoff, `visible_at` re-bumping. `visible_at` is
  introduced **now** so retry lands without another migration, but nothing mutates it
  this session (`visible_at == wait_until` for every row).

**Conscious consequence:** `delivering`/`delivered`/`failed` have **no producer** this
session — every task stays `pending`. Same pattern as today's reserved `waiting`:
schema and contract are ready, behavior follows.

## State machine

```
create ─────────────────────> pending        (visible_at = wait_until, in the future)
pending     --claim-------->   delivering      (worker picks it up; later phase)
delivering  --HTTP 2xx----->   delivered       terminal
delivering  --non-2xx/error->  failed          terminal
```

Four states: `pending`, `delivering` (non-terminal) · `delivered`, `failed` (terminal).
No retry: any delivery failure is terminal (`failed`), no reschedule.

## `visible_at` semantics

- The **scheduler column**: a task is eligible to run when `status = 'pending' AND visible_at <= now()`.
- Initialized to `wait_until` (`= created_at + wait_for`) at insert.
- Immutable this session (no retry mutates it). Mirrors Temporal's `visibility_timestamp`.
- `wait_until` remains the **immutable intent** exposed in `GET`; `visible_at` is internal
  scheduler state, **never** exposed in any response.

## Schema (migration)

New cigogne migration (`make migrate-new NAME=task_lifecycle_states`) that ALTERs the
existing `tasks` table in place (forward + reversible — no dev DB reset):

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

Notes:
- The inline `CHECK` from the create migration is auto-named `tasks_status_check`
  (Postgres `<table>_<column>_check`). Verify with `\d tasks` before relying on the name.
- After migrating, run `make sqlgen` — `insert_tasks` gains a `visible_at` param, so the
  squirrel-generated signature changes (squirrel introspects the live, migrated DB).

Resulting table:

```
id              uuid pk
idempotency_key text unique
wait_for        text          -- raw duration string, immutable
destination     text          -- http(s) url
wait_until      timestamptz    -- immutable intent (exposed in GET)
visible_at      timestamptz    -- NEW; scheduler; init = wait_until; internal
status          text          -- CHECK (pending|delivering|delivered|failed) default 'pending'
created_at      timestamptz
index (status, visible_at)     -- due-task scan
```

## Contract

### `POST /tasks`

- Input unchanged: `Idempotency-Key` header (UUID v4) + body `{"wait_for", "destination"}`.
- `202` body changes: `{"status":"accepted"}` → **`{"status":"pending"}`** (reflects the
  persisted initial state; `POST` and an immediate `GET` now agree).
- `429 + Retry-After` (load-shed) unchanged.
- `405` on wrong method unchanged.

### `GET /tasks/{key}`

- Body **shape unchanged**:
  ```json
  {
    "id": "<uuid>",
    "idempotency_key": "<uuid>",
    "status": "pending | delivering | delivered | failed",
    "wait_for": "<duration string>",
    "wait_until": "<rfc3339 utc>",
    "created_at": "<rfc3339 utc>",
    "destination": "<url>"
  }
  ```
- Only the `status` value domain changes. `visible_at` is **not** in the response.
- `404` / `500` / `405` behavior unchanged.

## Code touch points

- **`src/notyet/task/status.gleam`** — replace the enum:
  ```gleam
  pub type Status { Pending Delivering Delivered Failed }
  ```
  `to_string` / `from_string` map `pending`/`delivering`/`delivered`/`failed`. `Pending`
  is the initial state.
- **`src/notyet/task/record.gleam`** — `TaskRecord` gains `visible_at: Timestamp`.
- **`src/notyet/task.gleam`**
  - `create_with_key`: set `wait_until = timestamp.add(now, duration)` and
    `visible_at = wait_until` on the record.
  - `202` body uses `status.Pending` → `{"status":"pending"}`.
  - `row_to_task` unchanged in shape (still `status.from_string(row.status)`; now resolves
    the new values).
- **`src/notyet/task/view.gleam`** — unchanged (no `visible_at` field; `status` flows
  through `status.to_string`).
- **`src/notyet/task/batch.gleam`** — `do_insert` builds a `visibles` list and passes it;
  call becomes `sql.insert_tasks(db, ids, keys, wait_fors, dests, visibles, untils, createds)`.
- **`src/notyet/task/sql/insert_tasks.sql`** — add the `visible_at` column + a
  `$N::text[]` param cast to `timestamptz`:
  ```sql
  INSERT INTO tasks (id, idempotency_key, wait_for, destination, visible_at, wait_until, created_at)
  SELECT i::uuid, k, f, dest, v::timestamptz, w::timestamptz, c::timestamptz
  FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
    AS t(i, k, f, dest, v, w, c)
  ON CONFLICT (idempotency_key) DO NOTHING;
  ```
- **`src/notyet/task/sql/get_task_by_idempotency_key.sql`** — unchanged (`visible_at` not
  selected).
- **`src/notyet/task/sql.gleam`** — regenerated by `make sqlgen` (do not hand-edit).

## Testing

Test-driven, mirroring the existing layout.

- **`status_unit_test`** — `to_string`/`from_string` round-trip for all four values;
  unknown string → `Error`.
- **`view_unit_test`** — `encode` emits the new `status` strings; body still has no
  `visible_at`.
- **`handler_test`** — `POST` returns `202 {"status":"pending"}`; persisted row has
  `status='pending'` and `visible_at = wait_until`; `GET` round-trips the new status domain.
- **`batch_test` / `sql_integration_test`** — insert writes `visible_at`; assert it equals
  `wait_until` for inserted rows.
- **`router_integration_test`** — `202` body assertion updated to `pending`.

Coverage gaps closed with tests, not exclusions.

## Confirmed decisions

- States: `pending` / `delivering` / `delivered` / `failed`.
- `202` body → `{"status":"pending"}`.
- Terminal names → `delivered` / `failed`.
- `delivering` is a contract-visible state.
- `visible_at` kept (retry groundwork), init = `wait_until`, internal, immutable this session.
- No `attempts` / `last_error` / `lease_expires_at` / retry / worker this session.
- Forward ALTER migration (in place, reversible), not a table rewrite.
