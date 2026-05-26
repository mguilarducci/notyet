# Design: delivery target as a closed sum type (Webhook only)

**Date:** 2026-05-26
**Status:** draft

## Goal

Generalize **the target of a delivery** from today's fixed `destination` (a single
http(s) URL) into a **closed sum type** `Target`, while keeping the rest of the task
model (wait, idempotency, lifecycle, async write-behind) unchanged.

This session implements **only the `Webhook` variant** — but models the target as a
finite, owned sum type so future variants (`QueuePublish`, `Email`, …) are added by
**exhaustive code change**, not by degrading to an opaque blob. The compiler forces a
match arm in every `case`; the type stays queryable and validatable.

## Decisions (confirmed)

- **Closed sum type** `Target` in Gleam — not an open/injected handler, not `Dynamic`.
- **Postgres encoding: discriminator + bounded jsonb.** `target_kind TEXT` +
  `target_config JSONB`. Adding a variant is a code change (new sum-type arm + decode);
  the physical schema is a serialization detail under the closed type.
- **Validation lives in two layers, always:** (1) in code — the boundary decoder builds
  a typed `Target`, the closed sum type makes illegal states unrepresentable after
  decode; (2) in the database — a `CHECK` on `target_config` as defense-in-depth. Not an
  either/or.
- **Webhook shape:** `url`, `method`, `headers`, `body`.
- **Method:** closed set `GET | POST | PUT | PATCH | DELETE` (own sum type `Method`).
- **Headers:** `Dict(String, String)` (no duplicate names; serializes cleanly to a json
  object).
- **Body:** `Option(String)` — opaque; we never parse it, the delivery worker sends it
  raw.
- **Migration: squash.** Collapse the two existing migrations into a single fresh
  migration whose `tasks` table is born with `target_kind`/`target_config` and no
  `destination`. Safe because there is no production data and test/dev DBs are
  self-provisioned fresh via testcontainers, so collapsing migration history carries no
  operational risk.

## Scope

**In scope (this session):**
- `Target` sum type with the single `Webhook` variant + `Method` sum type.
- New `src/notyet/task/target.gleam`: types, boundary `decoder`, `encode` (response),
  `to_storage` (Target → `#(kind, config_json)`), `from_storage` (read-back).
- Schema: squashed migration with `target_kind` + `target_config JSONB` + per-kind
  `CHECK`. `destination` removed.
- API contract: `POST` body and `GET` response carry a nested `target` object instead of
  a flat `destination` string.
- Insert + read SQL regenerated for the new columns.

**Out of scope (later phases):**
- Any second variant (`QueuePublish`, `Email`). The sum type is closed at `Webhook`; a
  second arm is a future code change.
- The delivery worker that actually performs the webhook call (method, headers, body are
  modeled and stored now; nothing reads them to make an HTTP request this session).
- Per-field jsonb expression indexes (the scheduler scans `status`/`visible_at`, both
  top-level columns; no inner-config query is needed yet).

**Conscious consequence:** `method`/`headers`/`body` have **no consumer** this session —
they are persisted and read back, but no worker dispatches them. Same pattern as the
lifecycle states groundwork: schema and contract ready, behavior follows.

## Gleam types — `src/notyet/task/target.gleam`

```gleam
pub type Target {
  Webhook(
    url: String,
    method: Method,
    headers: Dict(String, String),
    body: Option(String),
  )
}

pub type Method {
  Get
  Post
  Put
  Patch
  Delete
}
```

`Method` gets `to_string` / `from_string` mapping the uppercase wire forms
(`"GET"`/`"POST"`/`"PUT"`/`"PATCH"`/`"DELETE"`), mirroring `status.gleam`.

## Validation in code (boundary decoder = the home)

`target.decoder() -> decode.Decoder(Target)` reads the discriminator field `"type"`,
then dispatches to the variant arm. For `webhook`:

- **url** — `validate.url_http` (existing: http/https scheme, non-empty host, no
  userinfo). Invalid → decode failure → `422`.
- **method** — string → `Method` via `from_string`; outside the set → `422`.
- **headers** — optional in the request (omitted → empty `Dict`). When present, a json
  object → `Dict(String, String)`. Each **name** is a valid RFC 7230 token and contains
  **no CR/LF**; each **value** contains **no CR/LF**. CRLF in a header is a
  request-splitting / header-injection vector and is rejected at the boundary → `422`.
  `to_storage` **always** serializes `headers` as an object (an empty Dict → `{}`), so
  the `target_config ? 'headers'` DB guard always holds.
- **body** — optional string; no parsing.

Unknown `"type"` → decode failure → `422`.

## API contract

### `POST /tasks`

- `Idempotency-Key` header (UUID v4) unchanged.
- Body replaces flat `destination` with nested `target`:
  ```json
  {
    "wait_for": "5 minutes",
    "target": {
      "type": "webhook",
      "url": "https://hooks.example.com/abc",
      "method": "POST",
      "headers": { "Authorization": "Bearer xyz" },
      "body": "{\"event\":\"ping\"}"
    }
  }
  ```
- `headers` may be `{}`; `body` may be omitted (→ `None`).
- `202 {"status":"pending"}`, `429 + Retry-After`, `405` unchanged.
- Any invalid target field → `422` (checked after the idempotency key, like today).

### `GET /tasks/{key}`

- Response replaces `destination` with the same `target` object:
  ```json
  {
    "id": "<uuid>",
    "idempotency_key": "<uuid>",
    "status": "pending | delivering | delivered | failed",
    "wait_for": "<duration string>",
    "wait_until": "<rfc3339 utc>",
    "created_at": "<rfc3339 utc>",
    "target": {
      "type": "webhook",
      "url": "...",
      "method": "POST",
      "headers": { "...": "..." },
      "body": "..."
    }
  }
  ```
- `body` key omitted from the response when `None`.
- `visible_at` still **not** exposed. `404` / `500` / `405` unchanged.

## Postgres (squashed migration)

Replace `priv/migrations/20260521004749-create_tasks.sql` and
`20260522210845-task_lifecycle_states.sql` with a single fresh migration:

```sql
--- migration:up
CREATE TABLE tasks (
    id              UUID PRIMARY KEY,
    idempotency_key TEXT NOT NULL,
    wait_for        TEXT NOT NULL,
    target_kind     TEXT NOT NULL CHECK (target_kind IN ('webhook')),
    target_config   JSONB NOT NULL,
    wait_until      TIMESTAMPTZ NOT NULL,
    visible_at      TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'delivering', 'delivered', 'failed')),
    created_at      TIMESTAMPTZ NOT NULL,
    CONSTRAINT tasks_webhook_config_check CHECK (
      target_kind <> 'webhook' OR (
            target_config ? 'url'     AND jsonb_typeof(target_config->'url')     = 'string'
        AND target_config ? 'method'  AND target_config->>'method' IN ('GET','POST','PUT','PATCH','DELETE')
        AND target_config ? 'headers' AND jsonb_typeof(target_config->'headers') = 'object'
        AND (NOT target_config ? 'body' OR jsonb_typeof(target_config->'body') = 'string')
      )
    )
);

CREATE UNIQUE INDEX tasks_idempotency_key_idx ON tasks (idempotency_key);
CREATE INDEX tasks_status_visible_at_idx ON tasks (status, visible_at);

--- migration:down
DROP TABLE tasks;

--- migration:end
```

Notes:
- The `? 'key'` presence guards are required: `jsonb_typeof(target_config->'absent')`
  returns `NULL`, and a `CHECK` only fails on `FALSE`, so an absent required key would
  otherwise slip through. Presence + type together close that.
- `body` is optional: absent **or** a string.
- The DB `CHECK` is defense-in-depth; the boundary decoder is the primary guarantee and
  enforces strictly more (real URL parse, CRLF rejection, header-name tokens) than SQL
  can express.

Resulting `target_config` for a webhook row:
```json
{ "url": "...", "method": "POST", "headers": { "k": "v" }, "body": "..." }
```
(`body` key omitted when `None`.)

## Storage encode / decode

- `to_storage(Target) -> #(String, String)` — returns `#("webhook", config_json_string)`.
  `config_json` builds the object: `method` via `Method` `to_string`, `headers` via
  `dict.to_list` → `json.object`, `body` → string or omitted.
- `from_storage(kind: String, config: String) -> Result(Target, Nil)` — parses the json
  string and decodes per `kind` back into a `Target`. Used by `row_to_task` under
  `let assert` (total against rows this service wrote through the constrained schema —
  same pattern as today's `row_to_task`).

## Code touch points

- **new `src/notyet/task/target.gleam`** — `Target`, `Method`, `decoder`, `encode`,
  `to_storage`, `from_storage`, `Method.to_string`/`from_string`.
- **`src/notyet/task/validate.gleam`** — add `header_name` / `header_value` validators
  (RFC 7230 token for names; no CR/LF in either). `url_http` unchanged.
- **`src/notyet/task/record.gleam`** — `TaskRecord` field `destination: String` →
  `target: Target`.
- **`src/notyet/task.gleam`**
  - `TaskRequest` field `destination: String` → `target: Target`.
  - `task_decoder`: `destination` field → `target` field via `target.decoder()`.
  - `create_with_key`: build the record with `target` (no other change to the flow).
  - `row_to_task`: `destination: row.destination` → `target: from_storage(...)` under
    `let assert`.
- **`src/notyet/task/view.gleam`** — `Task` field `destination: String` →
  `target: Target`; `encode` nests `target.encode(task.target)` under the `"target"` key.
- **`src/notyet/task/batch.gleam`** — `do_insert` builds `target_kinds` + `target_configs`
  lists from each record's `target` via `to_storage`, passes both to `sql.insert_tasks`.
- **`src/notyet/task/sql/insert_tasks.sql`**
  ```sql
  INSERT INTO tasks (id, idempotency_key, wait_for, target_kind, target_config, visible_at, wait_until, created_at)
  SELECT i::uuid, k, f, tk, tc::jsonb, v::timestamptz, w::timestamptz, c::timestamptz
  FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[])
    AS t(i, k, f, tk, tc, v, w, c)
  ON CONFLICT (idempotency_key) DO NOTHING;
  ```
- **`src/notyet/task/sql/get_task_by_idempotency_key.sql`** — select `target_kind` and
  `target_config::text AS target_config` (cast so squirrel decodes a `String`; the json
  is decoded in Gleam via `from_storage`).
- **`src/notyet/task/sql.gleam`** — regenerated by `make sqlgen` (do not hand-edit).

## Testing

Test-driven, mirroring the existing layout.

- **`target_unit_test`** (new) — `decoder`: valid webhook round-trips; bad url → fail;
  method outside set → fail; CRLF in header name/value → fail; invalid header-name token
  → fail; `body` absent → `None`; unknown `type` → fail. `Method` `to_string`/`from_string`
  round-trip + unknown → `Error`. `to_storage`/`from_storage` round-trip.
- **`view_unit_test`** — `encode` nests the `target` object; `body` omitted when `None`;
  no `destination` key; no `visible_at`.
- **`handler_test`** — `POST` with a webhook target persists `target_kind='webhook'` and a
  `target_config` matching the input; `GET` round-trips the nested `target`.
- **`batch_test` / `sql_integration_test`** — insert writes the jsonb config; read decodes
  it back into a `Webhook`.
- **`router_integration_test`** — `POST`/`GET` body shape uses `target`.

Coverage gaps closed with tests, not exclusions.

## Confirmed decisions

- Closed sum type `Target`; single `Webhook` variant this session.
- Encoding: discriminator `target_kind` + bounded `target_config JSONB`.
- Validation in code (closed type + decoder) **and** DB (`CHECK`), both layers.
- `Method` = `GET | POST | PUT | PATCH | DELETE` (closed).
- `headers` = `Dict(String, String)`; `body` = `Option(String)`, opaque.
- Header CRLF rejected at the boundary (injection guard).
- Migration squashed to a single fresh file; `destination` removed.
- No second variant and no delivery worker this session.
