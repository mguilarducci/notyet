# Design: rename `wait` → `task`, drop `data`/`activity`, rename `for` → `wait_for`, add `destination`

**Date:** 2026-05-22
**Status:** approved

## Goal

Reshape the existing `/wait` feature into `/tasks`:

- Rename the `wait` domain to `task` everywhere (modules, types, route, table, env vars, named process).
- Remove the `data` field and the `activity` field from the contract and storage.
- Rename the duration field `for` → `wait_for` (request body, response body, DB column).
- Add a required `destination` field (an `http`/`https` URL).
- Collapse to a single migration that creates the `tasks` table directly.

This is a mechanical reshape of an existing, tested feature — no new business logic, no status transitions.

## New contract

### `POST /tasks`

- Header `Idempotency-Key`: **UUID v4** (missing/empty/non-v4 → `422`, checked before the body; stored canonical lowercase). Unchanged from today.
- Body:
  ```json
  { "wait_for": "<duration string>", "destination": "<http(s) url>" }
  ```
  - `wait_for`: strict duration string (same grammar as today's `for`). Invalid/missing/non-string → `422`.
  - `destination`: **required** string, validated as an `http`/`https` URL (see below). Missing/non-string/invalid → `422`.
- Responses:
  - `202 {"status":"accepted"}` — enqueued into the write-behind buffer (ack-on-enqueue; persistence is async).
  - `429 + Retry-After: 1` — buffer full and all in-flight insert slots busy (load-shed). Retry safe via idempotency key.
- Wrong method on `/tasks` → `405`.

### `GET /tasks/{key}`

- `{key}` is the `Idempotency-Key`, a UUID v4 (validated + matched canonical; non-v4 → `404` without a DB query).
- `200` with the full resource:
  ```json
  {
    "id": "<uuid>",
    "idempotency_key": "<uuid>",
    "status": "accepted",
    "wait_for": "<duration string>",
    "wait_until": "<rfc3339 utc>",
    "created_at": "<rfc3339 utc>",
    "destination": "<url>"
  }
  ```
- `404` when the row does not exist (a `GET` right after a `202` may `404` until the async flush lands — read path queries Postgres only).
- `500` on query/connection error. `405` on wrong method.

No `data` field anywhere. No `activity` field anywhere. `destination` is always present (column is `NOT NULL`).

## `destination` validation

Validate with `gleam/uri`:

- `uri.parse(s)` must succeed.
- `scheme` must be `Some("http")` or `Some("https")`.
- `host` must be `Some(h)` with non-empty `h`.

Otherwise → `422`. The raw validated string is stored as-is (no normalization). A small private helper (e.g. `parse_http_url`) lives in `src/notyet/task.gleam`, mirroring the existing `parse_uuid_v4` pattern (validate-at-the-boundary in the decoder).

## Renames (`wait` → `task`)

### Files (source)

- `src/notyet/wait.gleam` → `src/notyet/task.gleam`
- `src/notyet/wait/` → `src/notyet/task/`: `batch.gleam`, `duration.gleam`, `record.gleam`, `sql.gleam`, `status.gleam`, `view.gleam`
- `src/notyet/wait/sql/*.sql` → `src/notyet/task/sql/*.sql`
- **Delete** `src/notyet/wait/json_value.gleam` (only consumer was `data`)

### Files (test)

- `test/notyet/wait/` → `test/notyet/task/` (all mirrored test modules)
- **Delete** `test/notyet/wait/json_value_unit_test.gleam`
- Update `test/test_helper.gleam` (`TRUNCATE waits` → `TRUNCATE tasks`, `count_waits` → `count_tasks`, etc.)
- Update `test/notyet_test.gleam` and `test/notyet/router_integration_test.gleam`

### Types

- `WaitRequest` → `TaskRequest`
- `WaitRecord` → `TaskRecord`
- `view.Wait` → `view.Task`
- `GetWaitByIdempotencyKeyRow` → `GetTaskByIdempotencyKeyRow` (squirrel-generated; comes from regenerating after the SQL file rename)

### Functions

- `wait_decoder` → `task_decoder`
- `get_wait_by_idempotency_key` → `get_task_by_idempotency_key`
- `insert_waits` → `insert_tasks`
- Handler entry points stay `create` / `read` (now `task.create` / `task.read`).

### Route

- `["wait"], Post` → `["tasks"], Post`
- `["wait"], _` → `["tasks"], _` (`405`)
- `["wait", key], Get` → `["tasks", key], Get`
- `["wait", _], _` → `["tasks", _], _` (`405`)

### Table / DB

- Table `waits` → `tasks`
- `waits_idempotency_key_idx` → `tasks_idempotency_key_idx`
- `waits_activity_idx` → **dropped** (activity removed)
- Named process `process.new_name("wait_batch")` → `"task_batch"`

### Env vars (`WAIT_*` → `TASK_*`)

Rename in `.env`, `.env.example`, `docker-compose.yml`, the `let assert Ok(...) = read_int(...)` calls in `src/notyet.gleam`, and `CLAUDE.md`:

- `WAIT_BATCH_MAX_SIZE` → `TASK_BATCH_MAX_SIZE`
- `WAIT_BATCH_INTERVAL_MS` → `TASK_BATCH_INTERVAL_MS`
- `WAIT_BATCH_MAX_IN_FLIGHT` → `TASK_BATCH_MAX_IN_FLIGHT`
- `WAIT_DB_POOL_SIZE` → `TASK_DB_POOL_SIZE`
- `WAIT_ENQUEUE_TIMEOUT_MS` → `TASK_ENQUEUE_TIMEOUT_MS`

(The `pool_size >= max_in_flight` boot assertion is unchanged in behavior.)

## Field removals

### `data`

Remove from: request decoder (`optional_field("data", ...)`), `TaskRequest`, `TaskRecord`, `view.Task`, `view.encode`, `insert_tasks` SQL (the `data` column + `NULLIF(d,'')::jsonb` + the array param), `get_task_by_idempotency_key` SQL (the `COALESCE(data::text,'')` select), and the migration column. Delete `json_value` module, its test, and the `decode_data` / `data_string` helpers.

### `activity`

Remove from: request decoder (`activity_decoder`), `TaskRequest`, `TaskRecord`, `view.Task`, `view.encode`, both SQL files, the migration column, and the `waits_activity_idx` index. Keep `parse_uuid_v4` — still used to validate the `Idempotency-Key`.

## `for` → `wait_for`

- Request body JSON field `"for"` → `"wait_for"`.
- Response body JSON field `"for"` → `"wait_for"`.
- DB column `for_duration` → `wait_for`.
- Record/view fields `for_duration` → `wait_for`; `WaitRequest.raw_for` → `TaskRequest.raw_wait_for`.
- The duration grammar/parser (`task/duration.gleam`) is unchanged.

## Migration (single)

Replace `priv/migrations/20260521004749-create_waits.sql` with a single migration that creates `tasks` directly (rename the file to `...-create_tasks.sql`):

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

Because this rewrites an already-applied migration, the dev DB must be reset: drop the Postgres container/volume, `make db-up`, `make migrate`, then `make sqlgen` (squirrel introspects the live, migrated DB to regenerate `task/sql.gleam`).

## SQL files

### `src/notyet/task/sql/insert_tasks.sql`

```sql
INSERT INTO tasks (id, idempotency_key, wait_for, destination, wait_until, created_at)
SELECT i::uuid, k, f, dest, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
  AS t(i, k, f, dest, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

(Columns: `id`, `idempotency_key`, `wait_for`, `destination`, `wait_until`, `created_at`. The `data` array param and `NULLIF` sentinel are gone; `activity` is gone.)

### `src/notyet/task/sql/get_task_by_idempotency_key.sql`

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

`batch.do_insert` drops the `activities` and `datas` lists and adds a `destinations` list; the call becomes `sql.insert_tasks(db, ids, keys, fors, dests, untils, createds)`.

## Confirmed decisions

- `wait_until` still derived from `wait_for` (`timestamp.add(now, duration)`) — unchanged.
- Status enum `accepted`/`waiting` unchanged.
- `destination` stored raw (validated, not normalized).
- Route is plural `/tasks`.
- Env vars renamed to `TASK_*`.
- Historical docs under `docs/superpowers/{plans,specs}` referencing `wait` are left as-is (only the migration is "deleted/replaced").

## Testing

Development is test-driven. Mirror the existing test layout under `test/notyet/task/`. Update DB-backed helpers (`test_helper`) to target `tasks`. Add coverage for `destination` validation (valid http, valid https, non-http scheme rejected, missing host rejected, missing field rejected). Drop all `data`/`activity`/`json_value` tests. Coverage gaps must be closed with tests, not exclusions.
