# GET /wait/{key} — read endpoint design

**Date:** 2026-05-21
**Status:** Approved (design); pending implementation plan

## Summary

Add a read endpoint that returns a previously-accepted wait by its
`Idempotency-Key`. This is the read counterpart to `POST /wait`, which today
acks enqueue (`202`) without echoing the persisted row. The write path is
asynchronous (write-behind coordinator), so a `GET` issued immediately after a
`202` may not find the row yet; that case returns `404` and the client retries.

## Contract

- **Route:** `GET /wait/{key}`, where `{key}` is the `idempotency_key` the
  client sent on `POST /wait`. The key is an opaque token, assumed URL-safe
  (a key containing `/` would break path segmentation — out of scope).
- **200 OK** — the row exists in Postgres. Body is the complete resource (below).
- **404 Not Found** — no row with that key. Indistinguishable from
  "accepted (202) but not yet flushed to Postgres": the read path reads only the
  database, never the coordinator's in-memory buffer. Clients retry. This keeps
  the read path decoupled from the coordinator actor (no new actor protocol
  message, no read-path/actor coupling).
- **405 Method Not Allowed** — `["wait", key]` with any non-`GET` method →
  `wisp.method_not_allowed([Get])`.
- **`GET /wait/`** (no key): `wisp.path_segments` drops the trailing slash →
  `["wait"]`, which falls through to the existing `["wait"], _ -> 405`. No empty
  key reaches the read handler.

### 200 response body (complete resource)

```json
{
  "id": "<uuid>",
  "activity": "<uuid v4>",
  "idempotency_key": "<key>",
  "status": "accepted",
  "for": "5 minutes",
  "wait_until": "2026-05-21T12:00:00Z",
  "created_at": "2026-05-21T11:55:00Z",
  "data": { "...": "..." }
}
```

- `data` is **omitted** when the column is SQL `NULL` (symmetric with the write
  side, where `data` is optional). When present it is the JSON object that was
  stored.
- `for` is the raw `for_duration` string as submitted.
- `wait_until` and `created_at` are RFC3339, UTC.
- `id` is the server-minted internal UUID. It is included because the agreed
  shape is the *complete* resource; the client does not need it to look the wait
  up (lookup is by `idempotency_key`).

## Architecture (read-model approach)

A domain read-model isolates the JSON shape from the database schema and from
the squirrel-generated row type. The encoder is pure and unit-testable without a
database.

### Layers / flow

```
router  ["wait", key], Get  → wait.read(req, ctx)
  → wisp.require_method(req, Get)        (handler re-asserts its own precondition)
  → sql.get_wait_by_idempotency_key(ctx.db, key)
  → row → view.Wait                      (mapping lives in the handler — the seam
                                          that knows persistence: data::text →
                                          json_value.decoder, status.from_string)
  → view.encode(wait) → 200
  empty result                            → 404
```

### New module: `src/notyet/wait/view.gleam`

Pure read-model. **No `sql`/`pog` import** — this is the isolation that
motivated the read-model choice over inline mapping.

- Type:
  ```
  pub type Wait {
    Wait(
      id: Uuid,
      activity: Uuid,
      idempotency_key: String,
      status: status.Status,
      for_duration: String,
      wait_until: Timestamp,
      created_at: Timestamp,
      data: Option(JsonValue),
    )
  }
  ```
- `pub fn encode(Wait) -> json.Json` — builds the 200 body. `data` field is
  emitted only when `Some`. Timestamps via `gleam/time/timestamp.to_rfc3339`
  (UTC). `status` via `status.to_string`. Unit-testable by constructing `Wait`
  directly, no DB.

### Handler: `wait.read` (in `src/notyet/wait.gleam`)

- `GET`-only (`wisp.require_method`), consistent with `create` re-asserting its
  own preconditions so direct unit calls stay correct.
- Calls `sql.get_wait_by_idempotency_key(ctx.db, key)`.
- On a returned row: maps row → `view.Wait`. This mapping is the persistence
  seam and lives in the handler module (which imports `sql` + `view`), keeping
  `view` decoupled from the generated SQL module:
  - `data` column selected as `::text` → `Option(String)`; when `Some`, parsed
    with `json.parse(text, json_value.decoder())` into a `JsonValue`. The write
    path stores only objects, so the round-trip is lossless (already proven by
    `json_value` tests).
  - `status` column is `String` → `status.from_string`. The schema
    `CHECK (status IN ('accepted','waiting'))` guarantees validity, so a
    `let assert Ok(...)` is justified (DB invariant, not user input).
  - `id`, `activity` decoded as `Uuid`; `wait_until`, `created_at` as
    `Timestamp` (whatever squirrel/pog generate for `uuid`/`timestamptz`).
- Empty result → `wisp.not_found()` (`404`).

### `web.Context` change

`Context` gains `db: pog.Connection` for the read path (the coordinator owns its
own connection internally; reads do not go through the actor).

```
pub type Context {
  Context(
    db: pog.Connection,
    batch: process.Subject(batch.Message),
    enqueue_timeout_ms: Int,
  )
}
```

- `notyet.gleam` already builds `db = pog.named_connection(pool_name)` (line 37)
  and passes it to the coordinator; reuse the same handle in the `Context`
  constructor.
- Test `Context` construction updates: `test_helper.dummy_connection` already
  exists for router-only tests; `handler_test` uses a real started pool.

### New SQL: `src/notyet/wait/sql/get_wait_by_idempotency_key.sql`

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

- `data::text` because squirrel does not decode `jsonb` cleanly; casting to text
  lets us reuse `json_value`.
- `id::text` / `activity::text` if squirrel's uuid decoding is awkward; otherwise
  let squirrel decode `uuid` directly. Final column casts settle during TDD
  against the live introspected schema.
- Regenerate the typed module with `make sqlgen` (needs a live, migrated DB).
- **No migration** — every column already exists in `waits`.

## Error handling

- Decode/parse of a stored row never fails for well-formed rows; the write path
  is the only writer and enforces shape. `status` and `data` parsing rely on DB
  invariants (`CHECK`, write-side object enforcement) → `let assert`.
- DB query error (connection lost, etc.) propagates as a crash rescued by
  `web.middleware` (`wisp.rescue_crashes`) → `500`, same as the rest of the app.

## Testing plan (TDD: failing test first)

- **`view_unit_test`** — `encode`: with and without `data`; `status` =
  `accepted` and `waiting`; timestamp RFC3339 formatting; `data` field omitted
  when `None`.
- **`sql_integration_test`** (extend) — insert a row, then
  `get_wait_by_idempotency_key` returns exactly that row; a missing key returns
  an empty result.
- **`handler_test`** — `read` returns `200` with the complete body for an
  existing wait; `404` for a missing key.
- **`router_integration_test`** — `GET /wait/{key}` dispatches to `read`
  (`200`/`404`); a non-`GET` method on `["wait", key]` → `405`.

## Out of scope

- Reading by internal `id`.
- Read-your-writes consistency (querying the coordinator buffer).
- Listing/filtering waits; pagination.
- Auth/scoping (consistent with the current endpoints).
