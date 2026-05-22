# Design: `Idempotency-Key` on `POST /wait`

**Date:** 2026-05-21
**Status:** Approved (design)
**Branch:** `feat/wait-persistence-batch` (extends the batched-persistence work)
**Scope:** Require an `Idempotency-Key` header on `POST /wait`; deduplicate writes by that key so a retry never creates a second wait and always returns the original (canonical) row. This closes the ack-timeout phantom-write gap and makes any ack timeout safe (an occasional timeout is recovered by an idempotent retry rather than producing duplicates).

## Problem

The write-behind batching actor acks on flush. If a flush stalls past `WAIT_BATCH_ACK_TIMEOUT_MS`, the handler returns `500` but the record stays in the buffer and is later inserted — a **phantom write**: the client saw failure, the row exists. A client retry then creates a *second* row. With a client-supplied idempotency key + a unique constraint, a retry collapses onto the original row, so the phantom write becomes harmless and the response is always consistent.

Idempotency also decouples the ack timeout from correctness: whatever its value, an occasional timeout is recovered by an idempotent retry rather than producing duplicates. We keep a comfortable `2s` ack with a fast `50ms` flush interval.

## Decisions (locked)

- **Transport:** HTTP header **`Idempotency-Key`** (industry standard; separates retry control from the domain payload). Read before decoding the body.
- **Required:** yes. Missing or empty (`""`) key → **422**.
- **Format:** opaque **non-empty string**, client-generated. Stored as `TEXT`. No UUID requirement (idempotency keys are opaque).
- **Reuse with a different payload:** the key identifies the operation. A reused key returns **`201` with the original persisted row**; the new `for`/`activity`/`data` are **ignored** (not a `409`).
- **Canonical response:** the `201` body always reflects the **persisted** row. On a dedup hit the response carries the *original* `id`/`created_at`/`for`, not the values the retry minted. This forces the ack to return the persisted row, not `Ok(Nil)`.
- **Dedup mechanism:** `UNIQUE (idempotency_key)` + a single upsert `INSERT … ON CONFLICT (idempotency_key) DO UPDATE SET id = waits.id RETURNING …` (the no-op `DO UPDATE` makes `RETURNING` emit the existing row on conflict, which `DO NOTHING` would not).
- **Intra-batch duplicates:** two pending records with the same key in one flush are grouped to a single insert row before building the `unnest` arrays (Postgres rejects `ON CONFLICT` affecting the same row twice in one statement); all waiters sharing a key receive the same canonical row.
- **Timing defaults:** `WAIT_BATCH_INTERVAL_MS=50`, `WAIT_BATCH_ACK_TIMEOUT_MS=2000`. The boot invariant `ack_timeout_ms > interval_ms` still holds.

## Contract changes

`POST /wait`:

| Input | Result |
|-------|--------|
| no `Idempotency-Key` header, or empty | `422` (before body decode) |
| valid header + valid body, new key | `201`, row inserted, response from inserted row |
| valid header + body, **key already used** | `201`, response from the **original** row; new payload ignored; no second row |
| retry after a `500`/timeout with the same key | `201` canonical (phantom write collapses onto the original) |
| `activity` missing/non-v4, bad `for`, non-object `data` | `422` (unchanged) |
| valid request but flush fails / ack times out | `500` (client retries with the same key) |
| wrong method | `405` (unchanged) |

`201` body unchanged in shape — `{id, activity, status, created_at, for}` — but now always sourced from the persisted (canonical) row.

## Architecture

### Migration — `priv/migrations/<ts>-add_idempotency_key_to_waits.sql`

```sql
--- migration:up
ALTER TABLE waits ADD COLUMN idempotency_key TEXT;
UPDATE waits SET idempotency_key = id::text WHERE idempotency_key IS NULL;
ALTER TABLE waits ALTER COLUMN idempotency_key SET NOT NULL;
CREATE UNIQUE INDEX waits_idempotency_key_idx ON waits (idempotency_key);

--- migration:down
DROP INDEX waits_idempotency_key_idx;
ALTER TABLE waits DROP COLUMN idempotency_key;

--- migration:end
```

The backfill (`id::text`) lets the `NOT NULL UNIQUE` column be added to a populated dev table without failure. A new migration (not an edit of `create_waits`) keeps cigogne's applied-migration tracking intact.

### Query — `src/notyet/wait/sql/insert_waits.sql` (regenerate with `make sqlgen`)

```sql
INSERT INTO waits (id, activity, idempotency_key, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, k, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, a, k, d, f, w, c)
ON CONFLICT (idempotency_key) DO UPDATE SET id = waits.id
RETURNING id, activity, idempotency_key, status, created_at, wait_until;
```

squirrel regenerates `insert_waits(db, List(String) ×7) -> Result(pog.Returned(InsertWaitsRow), _)`. `InsertWaitsRow` now carries `id: Uuid`, `activity: Uuid`, `idempotency_key: String`, `status: String`, `created_at: Timestamp`, `wait_until: Timestamp`. (`status` is text from the DB.)

### Types — `src/notyet/wait/record.gleam`

```gleam
pub type WaitRecord {
  WaitRecord(
    id: Uuid,
    activity: Uuid,
    idempotency_key: String,
    data: Option(JsonValue),
    for_duration: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}

/// The canonical persisted wait the batch writer returns to a waiter. On a
/// dedup hit this is the ORIGINAL row, not the values the retry minted.
pub type PersistedWait {
  PersistedWait(
    id: Uuid,
    activity: Uuid,
    status: Status,
    created_at: Timestamp,
    wait_until: Timestamp,
  )
}
```

`PersistedWait` imports `notyet/wait/status.{type Status}`. (`record.gleam` already breaks the `wait`↔`batch` cycle; both new types live here.)

### Batch writer — `src/notyet/wait/batch.gleam`

- `Ack` changes from `Result(Nil, Nil)` to **`Result(record.PersistedWait, Nil)`**.
- `flush`:
  1. Reverse `pending` to input order.
  2. **Group by `idempotency_key`**, preserving first occurrence, into distinct insert rows; keep the full list of waiters per key.
  3. Build the 7 `List(String)` arrays from the distinct rows; call `sql.insert_waits`.
  4. On `Ok(Returned(_, rows))`: build a `dict.Dict(String, PersistedWait)` keyed by `idempotency_key` (mapping each returned row, decoding `status` via `status.from_string`). Reply every waiter with `Ok(persisted_for_its_key)`; if a key is somehow absent from the result, that waiter gets `Error(Nil)`.
  5. On `Error(_)`: reply `Error(Nil)` to every waiter.
- `enqueue`/`enqueue_async` signatures keep their shape; the reply type is now `Ack = Result(PersistedWait, Nil)`.
- Timer/size-trigger/empty-buffer logic unchanged.

### Handler — `src/notyet/wait.gleam`

```gleam
pub fn create(req, ctx) {
  use <- wisp.require_method(req, Post)
  case request.get_header(req, "idempotency-key") {
    Error(_) -> wisp.unprocessable_content()
    Ok("") -> wisp.unprocessable_content()
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
          case batch.enqueue(ctx.batch, row, ctx.ack_timeout_ms) {
            Ok(persisted) -> persisted |> encode_response |> json.to_string |> wisp.json_response(201)
            Error(_) -> wisp.internal_server_error()
          }
        }
      }
    }
  }
}
```

`encode_response` now takes `record.PersistedWait` and reads `status` from it (`status.to_string(p.status)`), `id`/`activity`/`created_at`/`for` from the persisted row. Header read uses `gleam/http/request.get_header` (wisp `Request` is a gleam_http request; header names are case-insensitive).

### Config

`.env` / `.env.example`: `WAIT_BATCH_INTERVAL_MS=50`, `WAIT_BATCH_ACK_TIMEOUT_MS=2000`. No new variables. `notyet.gleam` boot asserts unchanged (`ack_timeout_ms > interval_ms` ⇒ `2000 > 50` holds).

## Testing (exhaustive, live Postgres)

- **`sql_integration_test`**: insert a key → row present; **same key twice → one row, the second call returns the first row's `id`**; two distinct keys → two rows; mixed data NULL/JSONB still correct; empty list no-op. Add: returned `status` is `"received"`.
- **`batch_test`**: two records with the **same `idempotency_key`** enqueued into one flush → both waiters get `Ok(PersistedWait)` with the **same `id`**, and exactly **one** row persisted (intra-batch dedup). Existing flush/interval/threshold/error/JSONB tests updated for the new record shape + `Ack` type.
- **`handler_test`**: missing `Idempotency-Key` → `422` (no row); empty key → `422`; happy path → `201` + persisted; **retry with same key + different `for`/`activity` → `201` with the same `id` as the first call, original values** (count stays 1); response `status` is `"received"`.
- **`router_integration_test`**: happy path sends the header; 405/404 unaffected.
- **`encoder_unit_test`**: `encode_response(PersistedWait)` emits `{id, activity, status, created_at, for}` with the persisted values.
- **`test_helper`**: a `select_wait_by_key` / id helper if needed to assert the canonical row.

## Files

| Action | Path |
|--------|------|
| New | `priv/migrations/<ts>-add_idempotency_key_to_waits.sql` |
| Edit | `src/notyet/wait/sql/insert_waits.sql` (idempotency_key + ON CONFLICT + RETURNING) |
| Regen | `src/notyet/wait/sql.gleam` (`make sqlgen`) |
| Edit | `src/notyet/wait/record.gleam` (`WaitRecord.idempotency_key` + `PersistedWait`) |
| Edit | `src/notyet/wait/batch.gleam` (`Ack` type, grouped flush, result mapping) |
| Edit | `src/notyet/wait.gleam` (header read, mint with key, `encode_response(PersistedWait)`) |
| Edit | `.env`, `.env.example` (interval 50 / ack 2000) |
| Edit | `test/notyet/wait/sql_integration_test.gleam`, `batch_test.gleam`, `handler_test.gleam`, `encoder_unit_test.gleam`, `test/notyet/router_integration_test.gleam`, `test/test_helper.gleam` |
| Edit | `CLAUDE.md` (header contract, idempotency semantics, new timing defaults) |

## Risks / verify during implementation

- **squirrel array param + ON CONFLICT**: confirm `make sqlgen` accepts the upsert and emits 7 `List(String)` params + the expanded `InsertWaitsRow`. If `RETURNING status` (text) maps oddly, adapt the row decode.
- **Intra-batch grouping correctness**: the group-by-key step must keep *all* waiters per key, not just the first, or duplicate-key callers in one batch would hang until timeout.
- **`status` decode**: `status.from_string` on the DB value; a value outside the CHECK set should be impossible, but decode failure must surface as `Error` (→ 500), not a panic in the actor.
- **Migration on populated dev DB**: the backfill handles existing rows; a clean `make db-down` (`-v`) + `make migrate` also works.

## Out of scope

- Idempotency-key TTL / expiry / storage of the original request payload for `409` divergence detection (we return the original, not `409`).
- Per-activity key scoping (keys are globally unique).
- Echoing/replaying `data`.
