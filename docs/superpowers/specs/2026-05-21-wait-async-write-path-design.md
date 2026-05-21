# Design: async write path for `POST /wait` (high load)

**Date:** 2026-05-21
**Status:** Approved (design)
**Branch:** `feat/wait-persistence-batch`
**Scope:** Redesign the `POST /wait` write path for very high write load: ack-on-enqueue (`202 Accepted`), the batch actor becomes a pure coordinator that spawns inserts off its own loop (pipelining), bounded in-flight concurrency with `429` load-shedding (real backpressure). Failure is best-effort (logged, then dropped). The read/polling endpoint is **out of scope** (future session).

This design is the canonical write-heavy pattern for a single-node service: **batch** to amortize per-write overhead, **bound + shed** to survive overload (a queue alone does not — by Little's Law, arrival > service rate grows the buffer to collapse). See **References**.

## Problem

Today the batch actor runs the synchronous `pog.execute` **inside** its message handler, so the actor is frozen for the full DB round-trip: no pipelining (throughput capped at `1/flush_latency`) and no backpressure (the mailbox grows unbounded under overload). The per-request ack-on-flush model also blocks one process per in-flight request. At very high load both properties are fatal.

## Decisions (locked)

- **Ack-on-enqueue.** `POST /wait` validates synchronously, hands the record to the actor, and returns **`202 Accepted` `{"status":"accepted"}`** immediately. The write happens asynchronously in the background.
- **Best-effort, no recovery.** A failed async flush is logged and dropped — no dead-letter, no staging, no synchronous "accepted" record. "If it fails, it fails." A client cannot be told synchronously whether the write succeeded.
- **Coordinator + spawned inserts.** A single coordinator actor owns the buffer and timers; on flush it **spawns a short-lived worker** to run the batch insert, then immediately returns to accept more enqueues. Inserts pipeline.
- **Bounded concurrency + load-shed.** At most `WAIT_BATCH_MAX_IN_FLIGHT` concurrent insert workers. When the buffer is full **and** all worker slots are busy, new `POST`s get **`429 Too Many Requests`** with a `Retry-After` header. Memory is bounded; the node is protected. (`429` over `503`: the load is real client demand exceeding admission, not the service being down — `429` + `Retry-After` is the correct semantic for a synchronous client to back off and retry. Idempotency-Key makes the retry safe.)
- **`idempotency_key` is the handle.** No app-returned id in the response. The future `GET /wait/{key}` (out of scope) will look up by key. Idempotency dedup (UNIQUE + upsert) stays — a client retry never creates a second row.
- **`status` initial value is `accepted`** (renamed from `received`), so the `202` response and the persisted row share one name. State machine: `Accepted` (initial) + `Waiting` (reserved).
- **Single coordinator, not sharded.** The coordinator's per-message work is O(1) (append/spawn); the real ceiling is Postgres write throughput, which sharding the coordinator does not raise. Sharding by key hash is explicitly deferred.

## Contract

`POST /wait` — header `Idempotency-Key` (non-empty) + body `{"for", "activity" (uuid v4), "data"?}`:

| Input / condition | Result |
|---|---|
| valid, accepted into buffer | `202 {"status":"accepted"}` |
| buffer full AND all in-flight slots busy | `429` + `Retry-After` |
| missing/empty `Idempotency-Key` | `422` |
| bad `for` / non-v4 `activity` / non-object `data` | `422` |
| wrong method | `405` |

Validation (`422`) is synchronous and unchanged. The `202` body carries no row — the persisted values are read later via the (future) `GET /wait/{key}`. The DB row persists with `status = 'accepted'`.

## Architecture

### Coordinator actor — `src/notyet/wait/batch.gleam` (rewritten, simpler)

Removed entirely (no synchronous row reply anymore): the `Ack = Result(PersistedWait, Nil)` type, `PersistedWait`, the per-waiter `rows_by_key` mapping, and reply-with-row. `enqueue` no longer blocks on a flush.

```gleam
pub opaque type Message {
  Enqueue(record: WaitRecord, reply: Subject(Result(Nil, Nil)))  // Ok = accepted, Error = 429
  FlushTick
  FlushDone
}

pub type Config {
  Config(max_size: Int, interval_ms: Int, max_in_flight: Int)
}

type State {
  State(
    db: pog.Connection,
    config: Config,
    self: Subject(Message),
    pending: List(WaitRecord),
    count: Int,
    in_flight: Int,
    timer: Option(Timer),
  )
}
```

- **`enqueue(subject, record, timeout_ms) -> Result(Nil, Nil)`** = `process.call`. `Ok(Nil)` → handler returns `202`; `Error(Nil)` → `429`. This is a fast in-memory call (no DB), so `timeout_ms` is small.
- **On `Enqueue`:**
  - If `count >= max_size && in_flight >= max_in_flight` → `process.send(reply, Error(Nil))`, `continue` (do **not** buffer). This is the shed.
  - Else → `process.send(reply, Ok(Nil))`; prepend record, `count + 1`; arm the interval timer if the buffer was empty; if now `count >= max_size && in_flight < max_in_flight` → `flush`.
- **`flush`:** if `pending` empty → `continue` (clear timer). Else snapshot `records = list.reverse(pending)`, **`dedup_by_key`** (kept — see risks), spawn a worker, set `pending: []`, `count: 0`, `in_flight + 1`, `timer: None`, `continue`. The worker:
  - runs `do_insert(db, records)`, on `Error` logs (e.g. `wisp.log_error`/`logging`) and drops, then
  - `process.send(self, FlushDone)`.
  The actor **monitors** the worker pid; a worker that crashes before sending `FlushDone` produces a monitor `Down` the actor treats as `FlushDone` (prevents an `in_flight` leak that would wedge the actor at permanent `429`).
- **On `FlushDone`** (or worker `Down`): `in_flight - 1`; if `count > 0 && in_flight < max_in_flight` → `flush` (drain the buffer held while slots were busy).
- **On `FlushTick`:** if `pending` non-empty and a slot is free → `flush`; else reschedule (or no-op; next `FlushDone`/`Enqueue` drains).

Memory bound: `pending ≤ max_size`; at most `max_in_flight` worker snapshots (each `≤ max_size`) → total buffered `≤ max_size * (1 + max_in_flight)`.

### Insert — `src/notyet/wait/sql/insert_waits.sql` (simplified)

No canonical-row return is needed (fire-and-forget). Dedup becomes `DO NOTHING`:

```sql
INSERT INTO waits (id, activity, idempotency_key, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, k, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, a, k, d, f, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

squirrel regenerates `insert_waits` with no result rows (the `RETURNING` + its timestamp-cast workaround go away). `do_insert` keeps building the seven `text[]` arrays.

### Handler — `src/notyet/wait.gleam`

`encode_response` and the row-shaped response are **removed** (no row in the `202`). `create`:

```gleam
pub fn create(req, ctx) {
  use <- wisp.require_method(req, Post)
  case request.get_header(req, idempotency_header) {
    Error(_) | Ok("") -> wisp.unprocessable_content()
    Ok(key) -> {
      use body <- wisp.require_json(req)
      case decode.run(body, wait_decoder()) {
        Error(_) -> wisp.unprocessable_content()
        Ok(wr) -> {
          let now = timestamp.system_time()
          let row = record.WaitRecord(
            id: uuid.v4(), activity: wr.activity, idempotency_key: key,
            data: wr.data, for_duration: wr.raw_for,
            wait_until: timestamp.add(now, wr.duration), created_at: now,
          )
          case batch.enqueue(ctx.batch, row, ctx.enqueue_timeout_ms) {
            Ok(_) -> json.object([#("status", json.string("accepted"))])
              |> json.to_string |> wisp.json_response(202)
            // Shed: real client demand exceeded admission. 429 + Retry-After
            // tells the client to back off; the Idempotency-Key makes retry safe.
            Error(_) -> wisp.response(429)
              |> wisp.set_header("retry-after", "1")
          }
        }
      }
    }
  }
}
```

`record.PersistedWait` is removed from `record.gleam`. `status.gleam` renames `Received` → `Accepted` (`to_string` → `"accepted"`; `from_string "accepted"`). `web.Context` carries `enqueue_timeout_ms` instead of `ack_timeout_ms`.

### Migration

The single `create_waits` migration is edited in place (nothing deployed): `status TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting'))`. Recreate the dev DB (`docker compose down -v`, `make db-up`, `make migrate`).

### App wiring — `src/notyet.gleam`

Read new env. Start the pog pool with `pog.pool_size(db_config, pool_size)`. Assert `pool_size >= max_in_flight` (otherwise inserts queue on the pool and pipelining is defeated). Build `Config(max_size, interval_ms, max_in_flight)` and `Context(batch:, enqueue_timeout_ms:)`.

## Configuration (all env, mandatory)

| Var | Meaning |
|---|---|
| `DATABASE_URL`, `SECRET_KEY_BASE`, `PORT` | unchanged |
| `WAIT_BATCH_MAX_SIZE` | rows per batch before a size-triggered flush |
| `WAIT_BATCH_INTERVAL_MS` | flush this long after the first pending row |
| `WAIT_BATCH_MAX_IN_FLIGHT` | max concurrent insert workers |
| `WAIT_DB_POOL_SIZE` | pog pool size; **must be `>= WAIT_BATCH_MAX_IN_FLIGHT`** (boot assert) |
| `WAIT_ENQUEUE_TIMEOUT_MS` | timeout for the in-memory enqueue call (small) |

**Removed:** `WAIT_BATCH_ACK_TIMEOUT_MS` (nothing blocks on a flush anymore).

## Testing (live Postgres)

Async means tests assert eventual persistence — poll `count_waits` until it reaches the expected value or a deadline (small helper, e.g. `test_helper.eventually(fn, expected, deadline_ms)`).

- **handler**: valid → `202`; missing/empty `Idempotency-Key` → `422`; bad `for`/non-v4 `activity`/non-object `data` → `422`; an accepted request is eventually persisted (`eventually count == 1`); a retry with the same key → eventually exactly 1 row (dedup).
- **overload/shed**: a writer started with `max_size: 1`, `max_in_flight: 1`, and a slow/blocked insert (or by saturating slots) → once buffer full + slot busy, the next `enqueue` returns `Error` → handler `429` (with a `Retry-After` header). Assert at least one `429` under saturation and that memory/state stays bounded.
- **batch/coordinator**: flush by size and by interval both persist; `in_flight` never exceeds `max_in_flight`; `FlushDone` frees a slot and a held batch drains; a worker crash does not leak `in_flight` (after the crash the actor still accepts and flushes). Pipelining: with `max_in_flight: 2` a second batch starts while the first is in flight.
- **sql**: `insert_waits` inserts N rows; same key twice → 1 row (`DO NOTHING`); intra-batch same key → 1 row, no error; empty list no-op.
- **router**: `405`/`404` unchanged.

## Files

| Action | Path |
|---|---|
| Edit | `priv/migrations/<ts>-create_waits.sql` (status `accepted`) |
| Edit | `src/notyet/wait/sql/insert_waits.sql` (`DO NOTHING`, no RETURNING) + regen `sql.gleam` |
| Edit | `src/notyet/wait/record.gleam` (remove `PersistedWait`) |
| Edit | `src/notyet/wait/status.gleam` (`Received` → `Accepted`) |
| Edit | `src/notyet/wait/batch.gleam` (coordinator + spawn + in-flight + monitor + shed; drop Ack/reply-row) |
| Edit | `src/notyet/wait.gleam` (202/429 + Retry-After, drop `encode_response`) |
| Edit | `src/notyet/web.gleam` (`enqueue_timeout_ms`) |
| Edit | `src/notyet.gleam` (pool_size, max_in_flight, assert, drop ack_timeout) |
| Edit | `.env`, `.env.example` (new vars, drop ack_timeout) |
| Edit | tests: `batch_test`, `handler_test`, `sql_integration_test`, `router_integration_test`, `test_helper` (eventually helper); remove `encoder_unit_test` (no `encode_response`) |
| Edit | `CLAUDE.md` |

## Risks / verify during implementation

- **Worker-crash monitoring is the trickiest piece.** Confirm the gleam_otp 1.2 / gleam_erlang API for receiving a monitor `Down` inside an actor (a `Selector` added via `actor.new_with_initialiser` + `actor.selecting`, mapping `process.Down` to a `Message`). If a clean selector proves impractical, the fallback is: the worker always sends `FlushDone` (DB errors are values, not panics), accepting that a true process crash leaks one in-flight slot — and add a watchdog/log. Decide during impl; do not ship a silent `in_flight` leak that wedges the actor at permanent `429`.
- **`ON CONFLICT DO NOTHING` with intra-batch duplicate keys**: `DO NOTHING` (unlike `DO UPDATE`) should not raise "cannot affect row a second time". `dedup_by_key` is **kept** as belt-and-suspenders regardless; a test asserts intra-batch same-key → 1 row, no error.
- **`pool_size >= max_in_flight`**: enforced by a boot assert; without it the spawned inserts serialize on the pool and pipelining is lost.
- **Test determinism**: async persistence needs an `eventually` poll, not a fixed sleep, to avoid flakiness; the shed test needs a deterministic way to saturate slots (e.g. a deliberately slow insert or `max_in_flight: 1` + back-to-back enqueues).

## Out of scope

- `GET /wait/{key}` and any read/polling path (future session).
- Dead-letter / staging / retry of failed async writes (best-effort; failures logged then dropped).
- Sharded coordinators (single coordinator only).
- Returning the persisted row (id/created_at/for) in the `202`.

## Future DB-side wins (not implemented, noted for later)

The application-side ceiling is Postgres write throughput. When the coordinator is no longer the limit, the next levers are DB-side and **not** part of this plan:

- **`synchronous_commit = off`** — acknowledge the commit before the WAL fsync. Large write-throughput gain for a small durability window (a crash can lose the last few hundred ms of commits). This is **consistent with the best-effort stance** already chosen here ("if it fails, it fails") and is the cheapest first win.
- **WAL / checkpoint tuning** (`max_wal_size`, `checkpoint_timeout`) — smooth out checkpoint-driven I/O spikes under sustained write load.
- **Table partitioning** (e.g. by `created_at`) and minimal indexing — keep the hot insert path cheap. Today only `waits_activity_idx` + the `UNIQUE` idempotency index exist; resist adding more.

Beyond a single node, the structural step is **sharding the write tier** (Citus, or app-level shard-by-key) — explicitly deferred (see Decisions).

## References

Patterns and benchmarks that informed this design:

- [Queue-Based Load Leveling — Azure Architecture Center](https://learn.microsoft.com/en-us/azure/architecture/patterns/queue-based-load-leveling) — async ack + buffer in front of a slower consumer.
- [Little's Law & Applying Back Pressure When Overloaded](https://gist.github.com/rponte/8489a7acf95a3ba61b6d012fd5b90ed3) — why a bounded queue + shed is required (an unbounded queue collapses when arrival > service rate).
- [Backpressure by Design 2025: Concurrency Limits & Admission Control](https://debugg.ai/resources/backpressure-by-design-2025-concurrency-limits-admission-control-queueing-patterns) — `max_in_flight` as an admission-control concurrency limit; `429`/`503` shedding.
- [Boosting Postgres INSERT performance with UNNEST — Tiger Data](https://www.tigerdata.com/blog/boosting-postgres-insert-performance) — `INSERT … SELECT unnest(...)` is 2–5× faster than `VALUES`; the win is at planning time.
- [INSERT vs Batch INSERT vs COPY — Tiger Data](https://www.tigerdata.com/learn/testing-postgres-ingest-insert-vs-batch-insert-vs-copy) — `COPY` only overtakes `UNNEST` above ~10k rows/batch and loses `ON CONFLICT`; for our batch sizes `UNNEST` is the right tool.
- [Write-Behind cache tradeoffs](https://blog.bugfree.ai/read-through-vs-write-behind-cache-tradeoffs) — ack-on-enqueue trades durability for throughput (the crash-loses-buffer risk we accept).
- [Tuning PostgreSQL for write-heavy workloads — CloudRaft](https://www.cloudraft.io/blog/tuning-postgresql-for-write-heavy-workloads) — `synchronous_commit`, WAL/checkpoint, partitioning (the future DB-side wins above).
