# Design: `activity` field + batched Postgres persistence + Docker

**Date:** 2026-05-20
**Status:** Draft (design)
**Scope:** Add a required `activity` (UUID v4) field to `POST /wait`; persist each accepted wait to Postgres through an in-memory **batching write-behind actor** (dam-and-flush); ship the service production-ready with Docker (multi-stage build, `postgres:18`, all config via env).

## Goal

Three changes land together:

1. `POST /wait` gains a **required** `activity` field — a UUID **v4** string. Missing / malformed / non-v4 → `422`.
2. Every accepted wait is **persisted** to a new `waits` table. Writes are not issued one-per-request: they are buffered and flushed to Postgres as a **single batch insert** (one `INSERT ... SELECT unnest(...)` query per flush).
3. The service runs in Docker: `postgres:18`, a one-shot migration service, and a slim production Erlang release of the app. **No hardcoded values anywhere — everything via environment variables.**

Example request:

```json
{ "for": "5 minutes", "activity": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "data": { "k": 1 } }
```

## Ecosystem check (done)

No published Gleam library provides write-behind batching / buffer-flush. Confirmed across Hex, `packages.gleam.run`, `gleam_otp`, and `pog`. `pog` has transactions + parameterized queries but no native batch API; `squirrel` allows **at most one SQL statement per file**. The batching actor is built in-house on `gleam_otp` primitives (`actor` + `process.send_after`). The single-statement `unnest` insert is what fits `squirrel`.

Reference implementation for the DB stack (pog + squirrel + cigogne, docker-compose, test harness): `../lisztomania-gleam`.

## Decisions (locked)

- **`activity`**: required, **strict UUID v4**. Parse with `youid` `uuid.from_string`; assert `uuid.version(u) == V4`. Any failure → `422`. Stored as a `UUID` column.
- **Persisted columns (full + raw duration)**: `id`, `activity`, `data` (JSONB), `for_duration` (raw request string, e.g. `"5 minutes"`), `wait_until` (timestamptz), `status`, `created_at` (timestamptz).
- **`id` + timestamps minted app-side** (not by the DB). Required because ack-on-flush replies to each waiter individually and `RETURNING` order from an `unnest` insert is not guaranteed to match input order. `id = uuid v4`; `created_at = now`; `wait_until = now + duration` — all from a **single `now` capture** (preserves the existing contract guarantee).
- **Write path = batching write-behind actor.** Handler hands its row to the actor and **blocks until that row's batch is committed** (ack-on-flush), then returns `201`. A failed flush replies `Error` to every waiter in the batch → those requests get `500`. **No silent loss**: a client only sees `201` after a committed write.
- **Flush trigger = size OR interval, whichever first.** Flush when the buffer reaches `WAIT_BATCH_MAX_SIZE` rows **or** `WAIT_BATCH_INTERVAL_MS` has elapsed since the first pending row.
- **Batch insert = single query**: `INSERT INTO waits (...) SELECT ... FROM unnest($1::text[], ...)`. One round-trip per flush, naturally atomic.
- **Response adds `activity` only**: `{id, activity, status, created_at, for}`. `data` stays received-but-not-echoed (unchanged from current contract).
- **`status` is a state machine; initial value is `received`** (not `waiting`). A new wait is persisted and returned with `status: "received"`. `waiting` remains a valid machine value for a later state; transitions between states are **out of scope** here (no code drives `received → waiting → …` yet). Modeled as a small Gleam type `Status` with `to_string`/`from_string`; the DB column constrains values with a `CHECK`.
- **Config is mandatory, no fallback.** `DATABASE_URL`, `WAIT_BATCH_MAX_SIZE`, `WAIT_BATCH_INTERVAL_MS`, `WAIT_BATCH_ACK_TIMEOUT_MS`, **and now `PORT` and `SECRET_KEY_BASE`** are all required; the app fails fast at boot (`let assert`) if any is missing/invalid. The current dev fallbacks for `PORT` (`8000`) and `SECRET_KEY_BASE` (dev default) are **removed** — full "tudo envvar", zero hardcoded literals.
- **Docker app = production Erlang shipment.** `gleam export erlang-shipment`, run on a slim Erlang image. Migrations run from a separate service built on the full toolchain stage (cigogne is a dev dep, absent from the shipment).
- **DB-touching tests run against a live Postgres** (`DATABASE_URL` from env), mirroring lisztomania's `test_helper` (`start_pool` / `with_db` TRUNCATE / `dummy` for non-DB routes). `gleam test` requires Postgres running + migrations applied.

## Architecture

```
mist → wisp_mist → router.handle_request(req, ctx)
     → web.middleware → wait.create(req, ctx)
          ├─ decode body (for + activity[v4] + data?)
          ├─ mint id, now, wait_until  (single now)
          ├─ build WaitRecord
          └─ process.call(ctx.batch, Enqueue(record, _), ACK_TIMEOUT_MS)   ← blocks
                                   │
                                   ▼
                         batch writer actor (supervised)
                         buffer: List(#(WaitRecord, reply))
                         flush on size OR interval timer
                                   │  (one batch)
                                   ▼
                         sql.insert_waits(db, [...lists...])   ← single unnest INSERT
                                   │
                         reply Ok/Error to every waiter in the flushed batch
```

Supervision tree (in `notyet.gleam`): `static_supervisor` (OneForOne) → pog pool child → batch writer child. The writer is started with the pog `Connection` + batch config; the router/handlers receive the writer's `Subject` via `Context`.

### Database schema — `priv/migrations/<ts>-create_waits.sql`

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

`id` has no `DEFAULT gen_random_uuid()` — the app always supplies it (no extension needed). `status` defaults to `'received'` (the state-machine initial state); the `CHECK` enumerates the machine's current values (`received`, `waiting`). Add new states to the `CHECK` as the machine grows.

### Request / decoder changes — `wait.gleam`

```gleam
pub type WaitRequest {
  WaitRequest(
    duration: Duration,
    raw_for: String,        // original "for" string, persisted verbatim
    activity: Uuid,
    data: Option(JsonValue),
  )
}
```

- New `activity_decoder()`: `decode.string` → `uuid.from_string` → on `Ok`, check `uuid.version(u) == uuid.V4`; else `decode.failure`. Covers missing (`decode.field` fails), non-string, non-UUID, and non-v4 → all `422`.
- `for` decoding now yields **both** the parsed `Duration` and the raw string. The field decoder captures the string; `duration_parser.parse` runs once; both stored on `WaitRequest`.
- `data` decoding unchanged (`json_value.object_decoder`, optional).

### `WaitRecord` (insert/response row)

A flat record the handler builds and both the actor and the response encoder consume:

```gleam
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

`status` is not stored on the record — a new wait is always created in the initial state `Received`, supplied at encode time and matched by the DB column default (`'received'`).

### Status state machine — `src/notyet/wait/status.gleam`

```gleam
pub type Status {
  Received
  Waiting
}

pub fn to_string(s: Status) -> String   // Received -> "received", Waiting -> "waiting"
pub fn from_string(s: String) -> Result(Status, Nil)
```

Initial state is `Received`. `Waiting` exists as a future state; nothing transitions to it yet (out of scope). `from_string` exists for decoding persisted rows when read paths are added. The encoder serializes the response `status` via `to_string(Received)`.

### JsonValue encoder — `json_value.gleam`

Add the long-deferred `encode(JsonValue) -> json.Json` (the comment in the module predicts it: "the encoder is added with storage"). Used to serialize `data` to a JSON string for the JSONB column. Round-trips the full ADT (`JObject`/`JArray`/`JString`/`JInt`/`JFloat`/`JBool`/`JNull`).

### Batch writer actor — `src/notyet/wait/batch.gleam`

Built on `gleam_otp` `actor`. Public surface:

- `Message` (opaque): `Enqueue(WaitRecord, reply: Subject(Result(Nil, Nil)))` and an internal `FlushTick`.
- `Config(max_size: Int, interval_ms: Int)`.
- `start(db: pog.Connection, config: Config) -> Result(Subject(Message), _)` — for the supervision tree.

State: `db`, `config`, `pending: List(#(WaitRecord, Subject(Result(Nil,Nil))))`, `timer: Option(Timer)`.

Behavior:

- **On `Enqueue`**: prepend `#(record, reply)` to `pending`. If `pending` was empty, schedule `FlushTick` via `process.send_after(self, interval_ms)` and store the timer. If `list.length(pending) >= max_size`, flush immediately (and cancel the pending timer).
- **On `FlushTick`**: flush whatever is pending.
- **Flush**: if `pending` is empty, no-op. Otherwise reverse `pending` to input order, split into the six column lists, call `sql.insert_waits(db, ...)`:
  - `Ok` → reply `Ok(Nil)` to every waiter.
  - `Error` → reply `Error(Nil)` to every waiter (→ handler returns `500`).
  - Clear `pending`; cancel/clear the timer.

The handler waits with `process.call(subject, Enqueue(record, _), ACK_TIMEOUT_MS)`. On timeout the call crashes the request → wisp `rescue_crashes` → `500` (no false `201`).

### Persistence query — `src/notyet/wait/sql/insert_waits.sql` (squirrel)

Single statement, all params as `text[]` (so `squirrel` generates `List(String)` params and we sidestep array-of-typed-value / nullable-array uncertainty). Absent `data` is passed as the empty string and mapped to SQL `NULL` via `NULLIF`:

```sql
INSERT INTO waits (id, activity, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
  AS t(i, a, d, f, w, c)
RETURNING id;
```

`gleam run -m squirrel` generates `sql.insert_waits(db, List(String), List(String), List(String), List(String), List(String), List(String))`. The actor maps each `WaitRecord` field: `uuid.to_string`, serialized JSON or `""`, raw duration, `timestamp.to_rfc3339(_, utc)`.

### Context — `web.gleam`

```gleam
pub type Context {
  Context(batch: process.Subject(batch.Message))
}
```

Handlers talk to the writer, never to a raw connection. Router-only tests (404/405) use a dummy subject that is never sent to.

### App wiring — `notyet.gleam`

Read mandatory env (`DATABASE_URL`, batch config, `PORT`, `SECRET_KEY_BASE`). Start supervised pog pool, start the batch writer in the same supervisor, build `Context(batch:)`, start mist.

### Docker

**`Dockerfile` (multi-stage):**

- `build` stage: `ghcr.io/gleam-lang/gleam:v1.x-erlang-alpine` → copy `gleam.toml`/`manifest.toml` → `gleam deps download` → copy source → `gleam export erlang-shipment` (output `build/erlang-shipment`). This stage retains the full toolchain incl. dev deps (cigogne).
- `runtime` stage: slim `erlang:*-alpine` → copy `build/erlang-shipment` → `ENTRYPOINT ["/app/entrypoint.sh", "run"]`. No gleam, no dev deps.

**`docker-compose.yml`:**

- `postgres`: `postgres:18-alpine`, env from `.env`, healthcheck (`pg_isready`), named volume.
- `migrate`: built from the `build` stage, `depends_on` postgres healthy, runs `gleam run -m cigogne`, one-shot (`service_completed_successfully`).
- `app`: built from the `runtime` stage, `depends_on` migrate completed, env from `.env`, exposes `PORT`.

Every value (`POSTGRES_*`, `DATABASE_URL`, `PORT`, `SECRET_KEY_BASE`, `WAIT_BATCH_*`) comes from `.env`. Add `.env.example`, `.dockerignore`, `priv/cigogne.toml`, and a `Makefile` (db-up, migrate, sqlgen, run, test) mirroring lisztomania.

## Configuration (all env, mandatory)

| Var | Meaning |
|-----|---------|
| `DATABASE_URL` | pog connection url (postgres://…) |
| `WAIT_BATCH_MAX_SIZE` | flush when buffer reaches this many rows |
| `WAIT_BATCH_INTERVAL_MS` | flush this long after the first pending row |
| `WAIT_BATCH_ACK_TIMEOUT_MS` | how long the handler waits for its batch to commit |
| `PORT` | server port (mandatory — fallback removed) |
| `SECRET_KEY_BASE` | wisp signing key (mandatory — dev fallback removed) |

**Constraints to document in `.env.example`:**
- `WAIT_BATCH_ACK_TIMEOUT_MS` **must exceed** `WAIT_BATCH_INTERVAL_MS` (plus insert time), or requests time out before their batch flushes.
- `WAIT_BATCH_INTERVAL_MS` + insert time should stay under pog's per-query timeout (default 5s) or the flush query aborts.

## Contract

`POST /wait` body: `{"for": <duration string>, "activity": <uuid v4>, "data"?: <json object>}`

| Input | Result |
|-------|--------|
| `for` valid, `activity` valid v4, no `data` | `201`, persisted (data NULL) |
| `for` valid, `activity` valid v4, `data` object | `201`, persisted |
| `activity` missing / non-string / not a UUID / not v4 | `422` |
| `for` missing/invalid | `422` (unchanged) |
| `data` present but not an object | `422` (unchanged) |
| valid request but batch flush fails / ack times out | `500` |
| wrong method | `405` (unchanged) |

`201` response: `{id, activity, status: "received", created_at, for}` (RFC3339 UTC, `Z`). `created_at = now`, `for = now + duration`.

## Testing (exhaustive, by design; live Postgres; mirrors src)

Coverage target is **every path enumerated** — same philosophy as the `data`-field spec: every ADT/enum variant, every decoder branch, every contract row, and every batch-actor state transition gets a test. No coverage tooling (Gleam has none turnkey); completeness is by construction.

**`test/test_helper.gleam`** (new, modeled on lisztomania): `start_pool()` (raw pog conn from `DATABASE_URL`, pool size 1), `with_db(fn)` (TRUNCATE `waits` then run), `start_batch(db, config)` (start a writer for handler/actor tests), `count_waits(db)` / `select_wait(db, id)` helpers for asserting persisted rows, `dummy_subject()` (unstarted subject for router-only tests).

- **`wait/duration_unit_test`** — unchanged.
- **`wait/json_value_unit_test`** — add encoder cases: **every** variant round-trips (`encode |> json.to_string` then re-decode equals original), incl. nested object/array, `JNull`, empty object `{}`, empty array `[]`, deeply nested, int vs float distinction, bool true/false.
- **`wait/status_unit_test`** (new) — `to_string(Received) == "received"`, `to_string(Waiting) == "waiting"`; `from_string("received") == Ok(Received)`, `from_string("waiting") == Ok(Waiting)`, `from_string("bogus") == Error(Nil)`; round-trip `to_string |> from_string` for every variant.
- **`wait/decoder_unit_test`** — `activity`: valid v4 → `Ok`; field missing → error; non-string (number/object) → error; non-UUID string → error; well-formed UUID but **non-v4** (v1, v7, nil-UUID) → error; uppercase/lowercase v4 both accepted. `for` valid + `activity` valid + `data` present/absent. `raw_for` captured **verbatim** (e.g. `"+5 minutes"`, `"05 minutes"` preserved). Combined failures (bad `for` AND bad `activity`) → error.
- **`wait/sql_integration_test`** (new, live DB) — `insert_waits` with N rows inserts exactly N (assert count + each row's columns); `data == ""` → column is SQL `NULL`; `data` non-empty → JSONB readable back equal; mixed batch (some NULL, some JSONB); single-row list; **empty list no-ops** (no query error, count unchanged); `for_duration` stored verbatim; `wait_until`/`created_at` round-trip as the timestamps sent; CHECK rejects an out-of-machine status (sanity).
- **`wait/batch_test`** (new, live DB) — every actor transition:
  - flush **by size**: enqueue exactly `max_size` rows → single flush, all waiters get `Ok`, exactly `max_size` rows persisted.
  - flush **by interval**: enqueue 1 row, wait > `interval_ms` → flushed, waiter `Ok`, row persisted.
  - **threshold boundary**: `max_size - 1` rows do NOT flush before the interval; the `max_size`-th triggers immediate flush and **cancels** the pending interval timer (no double flush / no second empty flush).
  - **multiple batches**: `2 * max_size + 1` enqueues → correct number of flushes, all rows persisted, all waiters `Ok`.
  - **error path**: force an insert error (e.g. violate the activity NOT NULL via a crafted record, or a closed/blocked connection) → every waiter in that batch gets `Error`; nothing persisted; actor survives and serves the next batch.
  - **empty flush**: a `FlushTick` with empty buffer is a no-op (no query, no crash).
- **`wait/handler_test`** (live DB + writer) — `201` with valid `data`; `201` without `data`; `422` `activity` missing; `422` `activity` non-v4; `422` `activity` malformed; `422` bad/missing `for`; `422` `data` not an object; response body contains `id`, `activity` (echoes input), `status: "received"`, `created_at`, `for`; `created_at`/`for` are RFC3339 `Z`; row persisted with matching `id`/`activity`/`for_duration`/`status='received'`; ack-timeout path → `500` (writer that never flushes within timeout).
- **`router_integration_test`** — `405` on wrong method (dummy subject); `404` unknown route (dummy subject); happy `POST /wait` end-to-end through writer+DB → `201` with `status: "received"`.
- **Boot/config** — covered by manual/`.env.example` documentation (missing mandatory env → `let assert` panic at startup). Not unit-tested (would require subprocess boot); the `let assert` pattern is the enforcement.

## Files

| Action | Path |
|--------|------|
| New | `priv/migrations/<ts>-create_waits.sql` |
| New | `priv/cigogne.toml` |
| New | `src/notyet/wait/status.gleam` (status state machine) |
| New | `src/notyet/wait/batch.gleam` (writer actor) |
| New | `src/notyet/wait/sql/insert_waits.sql` |
| New | `src/notyet/wait/sql.gleam` (squirrel-generated) |
| Edit | `src/notyet/wait.gleam` (WaitRequest + raw_for + activity decoder + WaitRecord + create) |
| Edit | `src/notyet/wait/json_value.gleam` (add `encode`) |
| Edit | `src/notyet/web.gleam` (Context holds batch Subject) |
| Edit | `src/notyet/router.gleam` (pass ctx through — likely unchanged) |
| Edit | `src/notyet.gleam` (mandatory env, pog pool + writer in supervisor) |
| Edit | `gleam.toml` (add `pog`, `gleam_otp`; dev `squirrel`, `cigogne`) |
| New | `test/test_helper.gleam` |
| New | `test/notyet/wait/status_unit_test.gleam` |
| Edit | `test/notyet/wait/decoder_unit_test.gleam` |
| Edit | `test/notyet/wait/json_value_unit_test.gleam` |
| New | `test/notyet/wait/batch_test.gleam` |
| New | `test/notyet/wait/sql_integration_test.gleam` |
| Edit | `test/notyet/wait/handler_test.gleam` |
| Edit | `test/notyet/router_integration_test.gleam` |
| New | `Dockerfile` (multi-stage) |
| New | `docker-compose.yml` |
| New | `.dockerignore`, `.env.example` |
| New | `Makefile` |
| Edit | `CLAUDE.md` (activity, persistence, batch writer, env, docker) |

## Risks / things to verify during implementation

- **squirrel array-param generation**: confirm `unnest($n::text[])` yields `List(String)` params. The all-`text[]` + `NULLIF`/casts design is chosen specifically to avoid nullable-array and typed-array uncertainty; revisit only if squirrel handles native types cleanly.
- **squirrel generation needs a live, migrated DB** (`gleam run -m squirrel` introspects types). Dev/CI must `make db-up && make migrate` before `make sqlgen`.
- **Ack timeout vs flush interval**: misconfiguration (timeout ≤ interval) turns every request into a `500`. Documented constraint + sane `.env.example` values.
- **Actor crash semantics**: pending-but-unacked rows are lost on a writer crash, but those clients never received `201` (they get `500`/timeout). Supervisor restarts the writer. Acceptable under ack-on-flush; **no false positives**.
- **erlang-shipment entrypoint**: confirm the generated `entrypoint.sh run` path and that mandatory env vars are present in the `app` service.

## Out of scope

- Reading/listing/expiring waits (no `GET`, no scheduler acting on `wait_until`).
- Echoing or storing-then-returning `data`.
- Retry / dead-letter for failed flushes (failure surfaces as `500`; client retries).
- Backpressure beyond the size trigger; shared/multi pool tuning.
- Coverage-measurement tooling.
