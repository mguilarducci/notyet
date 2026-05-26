# Delivery Target Sum Type (Webhook) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat `destination` string with a closed sum type `Target` (single `Webhook` variant this session), stored as `target_kind` + `target_config JSONB`, validated in code (decoder + closed type) and in the DB (CHECK).

**Architecture:** A new pure module `notyet/task/target.gleam` owns the `Target`/`Method` types, the boundary decoder (validation home), JSON encode (response), and storage encode/decode (Target ↔ jsonb). `record`, `task`, `view`, `batch`, and the SQL change from carrying a `destination: String` to carrying a `Target`. The Postgres migration history is squashed into one fresh migration (no prod data).

**Tech Stack:** Gleam, wisp, pog, squirrel (typed SQL gen), cigogne (migrations), gleeunit + testcontainers.

**Spec:** `docs/superpowers/specs/2026-05-26-delivery-target-sum-type-design.md`

---

## Implementation note on sequencing (read first)

Gleam compiles the whole project. Tasks 1–4 are **purely additive** (a new module + new
`validate` helpers consumed only by their own tests) so `gleam build` and `make test`
stay green throughout — real red/green TDD.

Task 5 changes the `sql.insert_tasks` signature and the row type, which ripples into
`record`/`batch`/`task`/`view` and **all** existing tests. `src/` is brought back to a
compiling state at the end of Task 5 (`gleam build` green); the existing **tests** are
updated in Task 6 (`make test` green). This split is deliberate: there is no
backwards-compat shim (no prod data), so the swap lands as one coherent change with the
`src` checkpoint after Task 5 and the full-suite checkpoint after Task 6.

DB-backed steps (`make sqlgen`, `make test`, `./bin/coverage`) need a running Docker
daemon + Elixir; they self-provision a throwaway Postgres via testcontainers.

---

## Task 1: `validate` header helpers

**Files:**
- Modify: `src/notyet/task/validate.gleam`
- Test: `test/notyet/task/validate_unit_test.gleam` (create)

- [ ] **Step 1: Write the failing tests**

Create `test/notyet/task/validate_unit_test.gleam`:

```gleam
import gleam/result
import notyet/task/validate

pub fn header_name_accepts_token_test() {
  assert result.is_ok(validate.header_name("X-Custom-Header"))
  assert result.is_ok(validate.header_name("Authorization"))
}

pub fn header_name_rejects_empty_test() {
  assert result.is_error(validate.header_name(""))
}

pub fn header_name_rejects_space_test() {
  assert result.is_error(validate.header_name("Bad Header"))
}

pub fn header_name_rejects_colon_test() {
  assert result.is_error(validate.header_name("X:Y"))
}

pub fn header_name_rejects_crlf_test() {
  assert result.is_error(validate.header_name("X\r\nInjected"))
}

pub fn header_value_accepts_plain_test() {
  assert result.is_ok(validate.header_value("Bearer abc.def"))
}

pub fn header_value_rejects_cr_test() {
  assert result.is_error(validate.header_value("a\rb"))
}

pub fn header_value_rejects_lf_test() {
  assert result.is_error(validate.header_value("a\nb"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `gleam test`
Expected: FAIL — `validate.header_name` / `validate.header_value` are unknown functions.

- [ ] **Step 3: Implement the helpers**

Append to `src/notyet/task/validate.gleam` (and add the two imports at the top):

```gleam
import gleam/list
import gleam/string
```

```gleam
/// RFC 7230 token characters allowed in a header field-name.
const token_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"

/// Validate a header name as a non-empty RFC 7230 token. Rejects spaces, colons,
/// control chars, and CR/LF — so a name can never inject a new header line.
pub fn header_name(name: String) -> Result(String, Nil) {
  case name != "" && list.all(string.to_graphemes(name), is_token_char) {
    True -> Ok(name)
    False -> Error(Nil)
  }
}

fn is_token_char(c: String) -> Bool {
  string.contains(does: token_chars, contain: c)
}

/// Validate a header value: anything without CR or LF. CR/LF is the
/// request-splitting / header-injection vector and is rejected.
pub fn header_value(value: String) -> Result(String, Nil) {
  case string.contains(value, "\r") || string.contains(value, "\n") {
    True -> Error(Nil)
    False -> Ok(value)
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `gleam test`
Expected: PASS (all `validate_unit_test` functions green).

- [ ] **Step 5: Commit**

```bash
git add src/notyet/task/validate.gleam test/notyet/task/validate_unit_test.gleam
git commit -m "feat(task): add header name/value validators (CRLF injection guard)"
```

---

## Task 2: `target` module — types + `Method`

**Files:**
- Create: `src/notyet/task/target.gleam`
- Test: `test/notyet/task/target_unit_test.gleam` (create)

- [ ] **Step 1: Write the failing tests**

Create `test/notyet/task/target_unit_test.gleam`:

```gleam
import gleam/result
import notyet/task/target

pub fn method_to_string_test() {
  assert target.method_to_string(target.Get) == "GET"
  assert target.method_to_string(target.Post) == "POST"
  assert target.method_to_string(target.Put) == "PUT"
  assert target.method_to_string(target.Patch) == "PATCH"
  assert target.method_to_string(target.Delete) == "DELETE"
}

pub fn method_from_string_roundtrip_test() {
  assert target.method_from_string("GET") == Ok(target.Get)
  assert target.method_from_string("POST") == Ok(target.Post)
  assert target.method_from_string("PUT") == Ok(target.Put)
  assert target.method_from_string("PATCH") == Ok(target.Patch)
  assert target.method_from_string("DELETE") == Ok(target.Delete)
}

pub fn method_from_string_unknown_test() {
  assert result.is_error(target.method_from_string("TRACE"))
  assert result.is_error(target.method_from_string("post"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `gleam test`
Expected: FAIL — module `notyet/task/target` does not exist.

- [ ] **Step 3: Create the module with types + Method functions**

Create `src/notyet/task/target.gleam`:

```gleam
import gleam/dict.{type Dict}
import gleam/option.{type Option}

/// The delivery target — a closed sum type. Only `Webhook` exists this session;
/// future variants (QueuePublish, Email) are added as new arms (code change),
/// keeping every `case` exhaustive.
pub type Target {
  Webhook(
    url: String,
    method: Method,
    headers: Dict(String, String),
    body: Option(String),
  )
}

/// HTTP method for a webhook delivery. Closed set.
pub type Method {
  Get
  Post
  Put
  Patch
  Delete
}

pub fn method_to_string(method: Method) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Patch -> "PATCH"
    Delete -> "DELETE"
  }
}

pub fn method_from_string(value: String) -> Result(Method, Nil) {
  case value {
    "GET" -> Ok(Get)
    "POST" -> Ok(Post)
    "PUT" -> Ok(Put)
    "PATCH" -> Ok(Patch)
    "DELETE" -> Ok(Delete)
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/task/target.gleam test/notyet/task/target_unit_test.gleam
git commit -m "feat(task): add Target/Method types with Method string mapping"
```

---

## Task 3: `target` module — boundary decoder

**Files:**
- Modify: `src/notyet/task/target.gleam`
- Test: `test/notyet/task/target_unit_test.gleam`

- [ ] **Step 1: Write the failing tests**

Append to `test/notyet/task/target_unit_test.gleam` (add the imports `gleam/dict`,
`gleam/dynamic/decode`, `gleam/json`, `gleam/option`):

```gleam
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}

fn decode_target(input: String) -> Result(target.Target, Nil) {
  case json.parse(input, target.decoder()) {
    Ok(t) -> Ok(t)
    Error(_) -> Error(Nil)
  }
}

pub fn decoder_accepts_full_webhook_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com/cb\",\"method\":\"POST\",\"headers\":{\"X-A\":\"b\"},\"body\":\"hi\"}"
  let assert Ok(target.Webhook(url, method, headers, body)) = decode_target(json)
  assert url == "https://x.com/cb"
  assert method == target.Post
  assert dict.get(headers, "X-A") == Ok("b")
  assert body == Some("hi")
}

pub fn decoder_defaults_headers_and_body_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"GET\"}"
  let assert Ok(target.Webhook(_, _, headers, body)) = decode_target(json)
  assert dict.size(headers) == 0
  assert body == None
}

pub fn decoder_rejects_bad_url_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"ftp://x.com\",\"method\":\"POST\",\"headers\":{}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_userinfo_url_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://u:p@x.com\",\"method\":\"POST\",\"headers\":{}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_bad_method_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"TRACE\",\"headers\":{}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_bad_header_name_test() {
  let json =
    "{\"type\":\"webhook\",\"url\":\"https://x.com\",\"method\":\"POST\",\"headers\":{\"Bad Name\":\"v\"}}"
  assert decode_target(json) == Error(Nil)
}

pub fn decoder_rejects_unknown_type_test() {
  let json = "{\"type\":\"smoke-signal\",\"url\":\"https://x.com\"}"
  assert decode_target(json) == Error(Nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `gleam test`
Expected: FAIL — `target.decoder` is unknown.

- [ ] **Step 3: Implement the decoder**

Add the imports to `src/notyet/task/target.gleam`:

```gleam
import gleam/dynamic/decode
import gleam/list
import gleam/result
import notyet/task/validate
```

Append:

```gleam
/// Boundary decoder: request JSON object → typed `Target`. Reads the `"type"`
/// discriminator, then runs the variant's decoder. This is the home of per-type
/// validation (url is a real http(s) URL, method is in-set, headers have valid
/// names and no CR/LF). A failure here becomes a 422.
pub fn decoder() -> decode.Decoder(Target) {
  use type_ <- decode.field("type", decode.string)
  case type_ {
    "webhook" -> webhook_decoder()
    _ -> decode.failure(placeholder(), "known target type")
  }
}

fn webhook_decoder() -> decode.Decoder(Target) {
  use url <- decode.field("url", url_decoder())
  use method <- decode.field("method", method_decoder())
  use headers <- decode.optional_field("headers", dict.new(), headers_decoder())
  use body <- decode.optional_field(
    "body",
    option.None,
    decode.map(decode.string, option.Some),
  )
  decode.success(Webhook(url:, method:, headers:, body:))
}

fn url_decoder() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case validate.url_http(s) {
    Ok(u) -> decode.success(u)
    Error(_) -> decode.failure("", "http(s) url")
  }
}

fn method_decoder() -> decode.Decoder(Method) {
  use s <- decode.then(decode.string)
  case method_from_string(s) {
    Ok(m) -> decode.success(m)
    Error(_) -> decode.failure(Get, "http method")
  }
}

fn headers_decoder() -> decode.Decoder(Dict(String, String)) {
  use raw <- decode.then(decode.dict(decode.string, decode.string))
  case list.all(dict.to_list(raw), valid_header) {
    True -> decode.success(raw)
    False -> decode.failure(dict.new(), "valid headers")
  }
}

fn valid_header(pair: #(String, String)) -> Bool {
  result.is_ok(validate.header_name(pair.0))
  && result.is_ok(validate.header_value(pair.1))
}

/// Default value for the `decode.failure` of an unknown type; never surfaced
/// (a failure decoder discards it).
fn placeholder() -> Target {
  Webhook("", Get, dict.new(), option.None)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/task/target.gleam test/notyet/task/target_unit_test.gleam
git commit -m "feat(task): add Target boundary decoder with per-type validation"
```

---

## Task 4: `target` module — encode + storage codec

**Files:**
- Modify: `src/notyet/task/target.gleam`
- Test: `test/notyet/task/target_unit_test.gleam`

- [ ] **Step 1: Write the failing tests**

Append to `test/notyet/task/target_unit_test.gleam`:

```gleam
fn sample() -> target.Target {
  target.Webhook(
    url: "https://x.com/cb",
    method: target.Post,
    headers: dict.from_list([#("X-A", "b")]),
    body: Some("hi"),
  )
}

fn field(body: String, key: String) -> String {
  let assert Ok(v) =
    json.parse(body, {
      use s <- decode.field(key, decode.string)
      decode.success(s)
    })
  v
}

pub fn encode_includes_type_and_fields_test() {
  let body = json.to_string(target.encode(sample()))
  assert field(body, "type") == "webhook"
  assert field(body, "url") == "https://x.com/cb"
  assert field(body, "method") == "POST"
}

pub fn encode_omits_body_when_none_test() {
  let no_body = target.Webhook(..sample(), body: None)
  let body = json.to_string(target.encode(no_body))
  let parsed =
    json.parse(body, {
      use b <- decode.field("body", decode.optional(decode.string))
      decode.success(b)
    })
  assert parsed == Ok(None)
}

pub fn to_storage_kind_and_config_test() {
  let #(kind, config) = target.to_storage(sample())
  assert kind == "webhook"
  // config carries the variant payload WITHOUT the discriminator.
  let has_type =
    json.parse(config, {
      use t <- decode.field("type", decode.optional(decode.string))
      decode.success(t)
    })
  assert has_type == Ok(None)
}

pub fn storage_roundtrip_test() {
  let #(kind, config) = target.to_storage(sample())
  assert target.from_storage(kind, config) == Ok(sample())
}

pub fn from_storage_unknown_kind_test() {
  assert target.from_storage("email", "{}") == Error(Nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `gleam test`
Expected: FAIL — `target.encode` / `target.to_storage` / `target.from_storage` unknown.

- [ ] **Step 3: Implement encode + storage codec**

Add the import to `src/notyet/task/target.gleam`:

```gleam
import gleam/json
```

Append:

```gleam
/// Serialize a `Target` to its `GET` response object (includes `"type"`).
pub fn encode(target: Target) -> json.Json {
  json.object([#("type", json.string(kind(target))), ..config_fields(target)])
}

/// Storage form: `#(kind, config_json)`. `config` is the variant payload as a
/// JSON string (no `"type"` — the kind lives in its own column).
pub fn to_storage(target: Target) -> #(String, String) {
  #(kind(target), json.to_string(json.object(config_fields(target))))
}

/// Inverse of `to_storage`. Total against rows this service wrote (the schema
/// CHECK + the boundary decoder constrain what reaches storage).
pub fn from_storage(kind: String, config: String) -> Result(Target, Nil) {
  case kind {
    "webhook" ->
      json.parse(config, webhook_decoder()) |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

fn kind(target: Target) -> String {
  case target {
    Webhook(..) -> "webhook"
  }
}

fn config_fields(target: Target) -> List(#(String, json.Json)) {
  case target {
    Webhook(url, method, headers, body) -> {
      let base = [
        #("url", json.string(url)),
        #("method", json.string(method_to_string(method))),
        #("headers", encode_headers(headers)),
      ]
      case body {
        option.Some(b) -> list.append(base, [#("body", json.string(b))])
        option.None -> base
      }
    }
  }
}

fn encode_headers(headers: Dict(String, String)) -> json.Json {
  headers
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
  |> json.object
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `gleam test`
Expected: PASS. Also run `gleam format src test` and `gleam build --warnings-as-errors`.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/task/target.gleam test/notyet/task/target_unit_test.gleam
git commit -m "feat(task): add Target JSON encode and jsonb storage codec"
```

---

## Task 5: schema swap + SQL + src consumers (src compiles green)

**Files:**
- Delete: `priv/migrations/20260522210845-task_lifecycle_states.sql`
- Overwrite: `priv/migrations/20260521004749-create_tasks.sql`
- Overwrite: `src/notyet/task/sql/insert_tasks.sql`
- Overwrite: `src/notyet/task/sql/get_task_by_idempotency_key.sql`
- Regenerate: `src/notyet/task/sql.gleam` (via `make sqlgen`)
- Modify: `src/notyet/task/record.gleam`
- Modify: `src/notyet/task/batch.gleam`
- Modify: `src/notyet/task.gleam`
- Modify: `src/notyet/task/view.gleam`

This task has no unit test of its own; the checkpoint is `gleam build` (src compiles) and
`make sqlcheck` (generated SQL matches). Existing tests are updated in Task 6.

- [ ] **Step 1: Squash the migration**

Delete `priv/migrations/20260522210845-task_lifecycle_states.sql`.

Overwrite `priv/migrations/20260521004749-create_tasks.sql` with the final schema:

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

- [ ] **Step 2: Rewrite the SQL query files**

Overwrite `src/notyet/task/sql/insert_tasks.sql`:

```sql
INSERT INTO tasks (id, idempotency_key, wait_for, target_kind, target_config, visible_at, wait_until, created_at)
SELECT i::uuid, k, f, tk, tc::jsonb, v::timestamptz, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::text[])
  AS t(i, k, f, tk, tc, v, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

Overwrite `src/notyet/task/sql/get_task_by_idempotency_key.sql`:

```sql
SELECT
  id::text,
  idempotency_key,
  status,
  wait_for,
  target_kind,
  target_config::text AS target_config,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at
FROM tasks
WHERE idempotency_key = $1;
```

- [ ] **Step 3: Regenerate the typed SQL module**

Run: `make sqlgen`
Expected: `src/notyet/task/sql.gleam` regenerated. `GetTaskByIdempotencyKeyRow` now has
fields `id, idempotency_key, status, wait_for, target_kind, target_config, wait_until,
created_at` (no `destination`); `insert_tasks` now takes 8 `List(String)` args.

Then: `make sqlcheck`
Expected: passes (generated SQL matches the `.sql` files).

- [ ] **Step 4: Update `record.gleam`**

Overwrite `src/notyet/task/record.gleam`:

```gleam
import gleam/time/timestamp.{type Timestamp}
import notyet/task/target.{type Target}
import youid/uuid.{type Uuid}

/// A fully-formed task ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. `visible_at` is the
/// scheduler column; it equals `wait_until` at creation. `target` is the typed
/// delivery target (serialized to `target_kind` + `target_config` on insert).
pub type TaskRecord {
  TaskRecord(
    id: Uuid,
    idempotency_key: String,
    wait_for: String,
    target: Target,
    visible_at: Timestamp,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
```

- [ ] **Step 5: Update `batch.gleam` `do_insert`**

Add the import near the other `notyet/task/*` imports in `src/notyet/task/batch.gleam`:

```gleam
import notyet/task/target
```

Replace the `do_insert` function (currently `src/notyet/task/batch.gleam:238-250`):

```gleam
fn do_insert(
  db: pog.Connection,
  records: List(TaskRecord),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let keys = list.map(records, fn(r) { r.idempotency_key })
  let wait_fors = list.map(records, fn(r) { r.wait_for })
  let storages = list.map(records, fn(r) { target.to_storage(r.target) })
  let kinds = list.map(storages, fn(s) { s.0 })
  let configs = list.map(storages, fn(s) { s.1 })
  let visibles = list.map(records, fn(r) { clock.rfc3339(r.visible_at) })
  let untils = list.map(records, fn(r) { clock.rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { clock.rfc3339(r.created_at) })
  sql.insert_tasks(
    db,
    ids,
    keys,
    wait_fors,
    kinds,
    configs,
    visibles,
    untils,
    createds,
  )
}
```

- [ ] **Step 6: Update `task.gleam`**

In `src/notyet/task.gleam`:

Add the import:

```gleam
import notyet/task/target
```

Replace the `TaskRequest` type (`task.gleam:21-23`):

```gleam
pub type TaskRequest {
  TaskRequest(duration: Duration, raw_wait_for: String, target: target.Target)
}
```

Delete the `destination_decoder` function (`task.gleam:34-40`).

Replace `task_decoder` (`task.gleam:42-50`):

```gleam
pub fn task_decoder() -> decode.Decoder(TaskRequest) {
  use parsed <- decode.field("wait_for", wait_for_decoder())
  use tgt <- decode.field("target", target.decoder())
  decode.success(TaskRequest(
    duration: parsed.0,
    raw_wait_for: parsed.1,
    target: tgt,
  ))
}
```

In `create_with_key`, replace the `record.TaskRecord(...)` construction
(`task.gleam:76-84`) so the `destination:` field becomes `target:`:

```gleam
      let row =
        record.TaskRecord(
          id: uuid.v4(),
          idempotency_key: key,
          wait_for: tr.raw_wait_for,
          target: tr.target,
          visible_at: wait_until,
          wait_until: wait_until,
          created_at: now,
        )
```

Replace `row_to_task` (`task.gleam:132-146`):

```gleam
fn row_to_task(row: sql.GetTaskByIdempotencyKeyRow) -> view.Task {
  let assert Ok(id) = uuid.from_string(row.id)
  let assert Ok(task_status) = status.from_string(row.status)
  let assert Ok(wait_until) = timestamp.parse_rfc3339(row.wait_until)
  let assert Ok(created_at) = timestamp.parse_rfc3339(row.created_at)
  let assert Ok(tgt) = target.from_storage(row.target_kind, row.target_config)
  view.Task(
    id: id,
    idempotency_key: row.idempotency_key,
    status: task_status,
    wait_for: row.wait_for,
    wait_until: wait_until,
    created_at: created_at,
    target: tgt,
  )
}
```

- [ ] **Step 7: Update `view.gleam`**

Overwrite `src/notyet/task/view.gleam`:

```gleam
import gleam/json
import gleam/time/timestamp.{type Timestamp}
import notyet/task/clock
import notyet/task/status.{type Status}
import notyet/task/target.{type Target}
import youid/uuid.{type Uuid}

/// The read-back shape of a task. Pure: no `sql`/`pog` dependency, so `encode`
/// is unit-testable without a database.
pub type Task {
  Task(
    id: Uuid,
    idempotency_key: String,
    status: Status,
    wait_for: String,
    wait_until: Timestamp,
    created_at: Timestamp,
    target: Target,
  )
}

/// Serialize a `Task` to the `200` response body. Timestamps are RFC3339, UTC.
pub fn encode(task: Task) -> json.Json {
  json.object([
    #("id", json.string(uuid.to_string(task.id))),
    #("idempotency_key", json.string(task.idempotency_key)),
    #("status", json.string(status.to_string(task.status))),
    #("wait_for", json.string(task.wait_for)),
    #("wait_until", json.string(clock.rfc3339(task.wait_until))),
    #("created_at", json.string(clock.rfc3339(task.created_at))),
    #("target", target.encode(task.target)),
  ])
}
```

- [ ] **Step 8: Verify src compiles**

Run: `gleam build --warnings-as-errors`
Expected: PASS — `src/` compiles. (`gleam test` will NOT pass yet; tests are updated in
Task 6.)

- [ ] **Step 9: Commit**

```bash
git add priv/migrations src/notyet/task/sql src/notyet/task/sql.gleam src/notyet/task/record.gleam src/notyet/task/batch.gleam src/notyet/task.gleam src/notyet/task/view.gleam
git commit -m "feat(task): persist delivery target as kind + jsonb config"
```

---

## Task 6: update existing tests to the target contract (suite green)

**Files:**
- Modify: `test/notyet/task/decoder_unit_test.gleam`
- Modify: `test/notyet/task/view_unit_test.gleam`
- Modify: `test/notyet/task/handler_test.gleam`
- Modify: `test/notyet/task/sql_integration_test.gleam`
- Modify: `test/notyet/task/batch_test.gleam`
- Modify: `test/notyet/router_integration_test.gleam`

- [ ] **Step 1: Rewrite `decoder_unit_test.gleam`**

Overwrite `test/notyet/task/decoder_unit_test.gleam` (now targets the task-level
`task_decoder`; per-field target validation is covered in `target_unit_test`):

```gleam
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/time/duration
import notyet/task

fn decode_json(
  input: String,
) -> Result(task.TaskRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, task.task_decoder())
}

const tgt = "{\"type\":\"webhook\",\"url\":\"http://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

pub fn valid_payload_decodes_test() {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> "}")
  assert req.duration == duration.seconds(300)
  assert req.raw_wait_for == "5 minutes"
  assert req.target == task_webhook()
}

fn task_webhook() -> task.TaskRequest {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> "}")
  req
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"wait_for\":\"bogus\",\"target\":" <> tgt <> "}")
    |> result.is_error
}

pub fn empty_wait_for_rejected_test() {
  assert decode_json("{\"wait_for\":\"\",\"target\":" <> tgt <> "}")
    |> result.is_error
}

pub fn missing_wait_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"wait_for\":123,\"target\":" <> tgt <> "}")
    |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) =
    decode_json(
      "{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> ",\"extra\":\"x\"}",
    )
  assert req.raw_wait_for == "5 minutes"
}

pub fn raw_wait_for_preserved_verbatim_test() {
  let assert Ok(req) =
    decode_json("{\"wait_for\":\"+5 minutes\",\"target\":" <> tgt <> "}")
  assert req.raw_wait_for == "+5 minutes"
}

pub fn target_required_test() {
  assert decode_json("{\"wait_for\":\"5 minutes\"}") |> result.is_error
}

pub fn target_invalid_rejected_test() {
  let bad =
    "{\"type\":\"webhook\",\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}"
  assert decode_json("{\"wait_for\":\"5 minutes\",\"target\":" <> bad <> "}")
    |> result.is_error
}
```

- [ ] **Step 2: Update `view_unit_test.gleam`**

Overwrite `test/notyet/task/view_unit_test.gleam`:

```gleam
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/time/timestamp
import notyet/task/status
import notyet/task/target
import notyet/task/view
import test_helper
import youid/uuid

const id_str = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

fn sample() -> view.Task {
  let assert Ok(id) = uuid.from_string(id_str)
  view.Task(
    id: id,
    idempotency_key: "k-1",
    status: status.Pending,
    wait_for: "5 minutes",
    wait_until: timestamp.from_unix_seconds(1_000_000),
    created_at: timestamp.from_unix_seconds(900_000),
    target: target.Webhook(
      url: "https://example.com/cb",
      method: target.Post,
      headers: dict.new(),
      body: None,
    ),
  )
}

pub fn encode_includes_core_fields_test() {
  let body = json.to_string(view.encode(sample()))
  assert test_helper.json_field(body, "id") == id_str
  assert test_helper.json_field(body, "idempotency_key") == "k-1"
  assert test_helper.json_field(body, "status") == "pending"
  assert test_helper.json_field(body, "wait_for") == "5 minutes"
}

pub fn encode_nests_target_test() {
  let body = json.to_string(view.encode(sample()))
  let assert Ok(#(type_, url)) =
    json.parse(body, {
      use t <- decode.subfield(["target", "type"], decode.string)
      use u <- decode.subfield(["target", "url"], decode.string)
      decode.success(#(t, u))
    })
  assert type_ == "webhook"
  assert url == "https://example.com/cb"
}

pub fn encode_omits_destination_key_test() {
  let body = json.to_string(view.encode(sample()))
  assert test_helper.json_field_missing(body, "destination")
}

pub fn encode_timestamps_are_rfc3339_utc_test() {
  let body = json.to_string(view.encode(sample()))
  let assert Ok(wu) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "wait_until"))
  assert wu == timestamp.from_unix_seconds(1_000_000)
  let assert Ok(ca) =
    timestamp.parse_rfc3339(test_helper.json_field(body, "created_at"))
  assert ca == timestamp.from_unix_seconds(900_000)
}

pub fn encode_status_delivered_test() {
  let delivered = view.Task(..sample(), status: status.Delivered)
  let body = json.to_string(view.encode(delivered))
  assert test_helper.json_field(body, "status") == "delivered"
}

pub fn encode_omits_visible_at_test() {
  let body = json.to_string(view.encode(sample()))
  assert test_helper.json_field_missing(body, "visible_at")
}
```

- [ ] **Step 3: Update `handler_test.gleam`**

Overwrite `test/notyet/task/handler_test.gleam`:

```gleam
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import notyet/task
import notyet/task/sql
import test_helper
import wisp/simulate

fn ctx(db) {
  test_helper.writer_ctx(db, 1, 200, 4)
}

const tgt = "{\"type\":\"webhook\",\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

const cfg = "{\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

fn body(wait_for: String) -> String {
  "{\"wait_for\":\"" <> wait_for <> "\",\"target\":" <> tgt <> "}"
}

pub fn create_accepts_and_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 minutes"), test_helper.v4)
    |> task.create(ctx(db))
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "pending"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_bad_wait_for_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 banana"), test_helper.v4)
    |> task.create(ctx(db))
  assert response.status == 422
}

pub fn create_bad_target_422_test() {
  use db <- test_helper.with_db
  let bad =
    "{\"type\":\"webhook\",\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}"
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"target\":" <> bad <> "}",
      test_helper.v4,
    )
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn missing_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Post, "/tasks")
    |> simulate.string_body(body("5 minutes"))
    |> request.set_header("content-type", "application/json")
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn empty_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 minutes"), "")
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

pub fn non_v4_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(body("5 minutes"), "not-a-uuid")
    |> task.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_tasks(db) == 0
}

fn seed(db, key) {
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [test_helper.v4],
      [key],
      ["5 minutes"],
      ["webhook"],
      [cfg],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  Nil
}

pub fn read_returns_200_with_resource_test() {
  use db <- test_helper.with_db
  seed(db, test_helper.v4)
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(db), test_helper.v4)
  assert response.status == 200
  let resp_body = simulate.read_body(response)
  assert test_helper.json_field(resp_body, "idempotency_key") == test_helper.v4
  assert test_helper.json_field(resp_body, "status") == "pending"
  assert test_helper.json_field(resp_body, "wait_for") == "5 minutes"
  let assert Ok(url) =
    json.parse(resp_body, {
      use u <- decode.subfield(["target", "url"], decode.string)
      decode.success(u)
    })
  assert url == "https://example.com/cb"
}

pub fn read_missing_key_returns_404_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4_b)
    |> task.read(ctx(db), test_helper.v4_b)
  assert response.status == 404
}

pub fn read_non_v4_key_returns_404_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Get, "/tasks/not-a-uuid")
    |> task.read(ctx(db), "not-a-uuid")
  assert response.status == 404
}

pub fn uppercase_key_canonicalized_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let upper = "F47AC10B-58CC-4372-A567-0E02B2C3D479"
  let created =
    test_helper.keyed_request(body("5 minutes"), upper)
    |> task.create(context)
  assert created.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
  let got =
    simulate.request(http.Get, "/tasks/" <> upper)
    |> task.read(context, upper)
  assert got.status == 200
  assert test_helper.json_field(simulate.read_body(got), "idempotency_key")
    == test_helper.v4
}

pub fn retry_same_key_persists_once_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let first =
    test_helper.keyed_request(body("5 minutes"), test_helper.v4)
    |> task.create(context)
  let second =
    test_helper.keyed_request(body("1 hour"), test_helper.v4)
    |> task.create(context)
  assert first.status == 202
  assert second.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn read_query_error_returns_500_test() {
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(test_helper.broken_pool()), test_helper.v4)
  assert response.status == 500
}

pub fn read_wrong_method_returns_405_test() {
  use db <- test_helper.with_db
  let response =
    simulate.request(http.Post, "/tasks/" <> test_helper.v4)
    |> task.read(ctx(db), test_helper.v4)
  assert response.status == 405
}
```

- [ ] **Step 4: Update `sql_integration_test.gleam`**

Overwrite `test/notyet/task/sql_integration_test.gleam`:

```gleam
import gleam/dict
import gleam/option.{None}
import gleam/time/timestamp
import notyet/task/sql
import notyet/task/target
import pog
import test_helper

const v4_a = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

const ts = "2026-05-20T12:00:00Z"

const kind = "webhook"

const cfg = "{\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

pub fn insert_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(
      db,
      [v4_a, v4_b],
      ["k-a", "k-b"],
      ["5 minutes", "1 hour"],
      [kind, kind],
      [cfg, cfg],
      [ts, ts],
      [ts, ts],
      [ts, ts],
    )
  assert count == 2
  assert test_helper.count_tasks(db) == 2
}

pub fn insert_single_row_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(db, [v4_a], ["k-a"], ["1 day"], [kind], [cfg], [ts], [ts], [
      ts,
    ])
  assert count == 1
}

pub fn empty_list_no_op_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_tasks(db, [], [], [], [], [], [], [], [])
  assert count == 0
  assert test_helper.count_tasks(db) == 0
}

pub fn get_by_key_returns_inserted_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a],
      ["look-me-up"],
      ["5 minutes"],
      [kind],
      [cfg],
      [ts],
      [ts],
      [ts],
    )
  let assert Ok(pog.Returned(count, [row])) =
    sql.get_task_by_idempotency_key(db, "look-me-up")
  assert count == 1
  assert row.id == v4_a
  assert row.idempotency_key == "look-me-up"
  assert row.status == "pending"
  assert row.wait_for == "5 minutes"
  assert row.target_kind == "webhook"
  let assert Ok(decoded) = target.from_storage(row.target_kind, row.target_config)
  assert decoded
    == target.Webhook(
      url: "https://example.com/cb",
      method: target.Post,
      headers: dict.new(),
      body: None,
    )
  let assert Ok(expected) = timestamp.parse_rfc3339(ts)
  let assert Ok(returned_wait_until) = timestamp.parse_rfc3339(row.wait_until)
  assert returned_wait_until == expected
  let assert Ok(returned_created_at) = timestamp.parse_rfc3339(row.created_at)
  assert returned_created_at == expected
}

pub fn get_by_key_missing_returns_empty_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, rows)) =
    sql.get_task_by_idempotency_key(db, "nope")
  assert count == 0
  assert rows == []
}

pub fn same_key_dedups_to_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_a], ["key-1"], ["5 minutes"], [kind], [cfg], [ts], [
      ts,
    ], [ts])
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_b], ["key-1"], ["1 hour"], [kind], [cfg], [ts], [
      ts,
    ], [ts])
  assert test_helper.count_tasks(db) == 1
}

pub fn intra_batch_same_key_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [v4_a, v4_b],
      ["same", "same"],
      ["1 day", "1 day"],
      [kind, kind],
      [cfg, cfg],
      [ts, ts],
      [ts, ts],
      [ts, ts],
    )
  assert test_helper.count_tasks(db) == 1
}

pub fn distinct_keys_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_a], ["key-1"], ["1 day"], [kind], [cfg], [ts], [ts], [
      ts,
    ])
  let assert Ok(_) =
    sql.insert_tasks(db, [v4_b], ["key-2"], ["1 day"], [kind], [cfg], [ts], [ts], [
      ts,
    ])
  assert test_helper.count_tasks(db) == 2
}
```

- [ ] **Step 5: Update `batch_test.gleam` record builder**

In `test/notyet/task/batch_test.gleam`, add imports:

```gleam
import gleam/dict
import gleam/option.{None}
import notyet/task/target
```

Replace the `rec` function (`batch_test.gleam:10-20`):

```gleam
fn rec() -> record.TaskRecord {
  record.TaskRecord(
    id: uuid.v4(),
    idempotency_key: uuid.v4_string(),
    wait_for: "5 minutes",
    target: target.Webhook(
      url: "https://example.com/cb",
      method: target.Post,
      headers: dict.new(),
      body: None,
    ),
    visible_at: timestamp.system_time(),
    wait_until: timestamp.system_time(),
    created_at: timestamp.system_time(),
  )
}
```

- [ ] **Step 6: Update `router_integration_test.gleam`**

Overwrite `test/notyet/router_integration_test.gleam`:

```gleam
import gleam/dynamic/decode
import gleam/http
import gleam/json
import notyet/router
import notyet/task/sql
import test_helper
import wisp/simulate

fn dummy_ctx() {
  test_helper.writer_ctx(test_helper.dummy_connection(), 1, 200, 4)
}

const tgt = "{\"type\":\"webhook\",\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

const cfg = "{\"url\":\"https://example.com/cb\",\"method\":\"POST\",\"headers\":{}}"

fn post_body() -> String {
  "{\"wait_for\":\"5 minutes\",\"target\":" <> tgt <> "}"
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Put, "/tasks") |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown") |> router.handle_request(dummy_ctx())
  assert response.status == 404
}

pub fn get_task_returns_200_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let assert Ok(_) =
    sql.insert_tasks(
      db,
      [test_helper.v4],
      [test_helper.v4],
      ["5 minutes"],
      ["webhook"],
      [cfg],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
      ["2026-05-20T12:00:00Z"],
    )
  let response =
    simulate.request(http.Get, "/tasks/" <> test_helper.v4)
    |> router.handle_request(ctx)
  assert response.status == 200
  let body = simulate.read_body(response)
  assert test_helper.json_field(body, "idempotency_key") == test_helper.v4
  let assert Ok(url) =
    json.parse(body, {
      use u <- decode.subfield(["target", "url"], decode.string)
      decode.success(u)
    })
  assert url == "https://example.com/cb"
}

pub fn get_task_missing_returns_404_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    simulate.request(http.Get, "/tasks/missing")
    |> router.handle_request(ctx)
  assert response.status == 404
}

pub fn get_task_wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Delete, "/tasks/whatever")
    |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn post_task_happy_path_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    test_helper.keyed_request(post_body(), test_helper.v4)
    |> router.handle_request(ctx)
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "pending"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn post_task_missing_target_422_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    test_helper.keyed_request("{\"wait_for\":\"5 minutes\"}", test_helper.v4)
    |> router.handle_request(ctx)
  assert response.status == 422
}

pub fn post_task_invalid_target_422_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let bad =
    "{\"type\":\"webhook\",\"url\":\"ftp://x\",\"method\":\"POST\",\"headers\":{}}"
  let response =
    test_helper.keyed_request(
      "{\"wait_for\":\"5 minutes\",\"target\":" <> bad <> "}",
      test_helper.v4,
    )
    |> router.handle_request(ctx)
  assert response.status == 422
}
```

- [ ] **Step 7: Run the full suite + coverage**

Run: `gleam format src test`
Run: `gleam build --warnings-as-errors`
Run: `make test`
Expected: all tests PASS.

Run: `./bin/coverage`
Expected: PASS the dual gate (lines ≥ 80%, clauses ≥ 90%). If `target.gleam` clauses are
below the floor, add unit tests in `target_unit_test` for the uncovered arms (e.g. each
`method_to_string` arm, `from_storage` unknown kind) — close gaps with tests, never
exclusions.

- [ ] **Step 8: Commit**

```bash
git add test
git commit -m "test(task): update suite to the target sum-type contract"
```

---

## Self-Review (completed inline)

**1. Spec coverage:**
- Closed `Target` + `Webhook` → Task 2.
- `Method` closed set `GET|POST|PUT|PATCH|DELETE` → Task 2 (+ DB CHECK Task 5).
- Boundary decoder (validation home): url / method / headers / body, CRLF guard → Task 1 (helpers) + Task 3 (decoder).
- `headers` = `Dict`, `body` = `Option` → Tasks 2–4.
- Encode (response) + storage codec → Task 4.
- `target_kind` + `target_config JSONB` + per-kind CHECK + squash migration → Task 5.
- Insert/read SQL + squirrel regen → Task 5.
- `record`/`batch`/`task`/`view` swap → Task 5.
- API request/response shape (`target` object) → exercised in Tasks 3 (decode) and 6 (handler/router).
- Read-back `from_storage` under `let assert` → Task 5 (`row_to_task`).
- Tests mirroring layout → Tasks 1–6.

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output.

**3. Type consistency:** `method_to_string`/`method_from_string`, `to_storage`/`from_storage`, `Webhook(url, method, headers, body)`, `TaskRecord.target`, `view.Task.target`, `GetTaskByIdempotencyKeyRow.{target_kind,target_config}`, and the 8-arg `sql.insert_tasks` are used consistently across tasks. `target` module alias vs local binding resolved by using `tgt` in `task.gleam`.

---
