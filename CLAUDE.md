# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

A `Makefile` wraps the common flows (it loads `.env` and exports it, so DB-backed targets get `DATABASE_URL`). One command per line — no compound shell anywhere in this repo (Makefile, scripts, Dockerfile, compose).

DB-backed targets are **self-provisioning**: they boot their own throwaway `postgres:18-alpine` via **testcontainers** and migrate it in-process (cigogne library API), so they need only a running **Docker daemon** and **Elixir** (a transitive requirement of `testcontainers_gleam`) — no `make db-up`/`make migrate` first. `make db-up`/`migrate` remain for running the app locally and for the containerized stack.

- `make db-up` — start the dev Postgres container for `make run` (`docker compose up -d postgres`)
- `make migrate` — apply pending migrations against `DATABASE_URL` (`gleam run -m cigogne all`)
- `make migrate-new NAME=foo` — scaffold a new migration in `priv/migrations`
- `make sqlgen` — regenerate typed query modules from `*.sql` (`gleam run -m squirrel_db`); self-provisions a migrated testcontainers DB for squirrel to introspect
- `make sqlcheck` — verify the generated SQL matches the `*.sql` (`gleam run -m squirrel_db -- check`); self-provisions like `sqlgen`
- `make test` — run the full gleeunit suite. Self-provisions the test DB via testcontainers (needs Docker + Elixir); no manual DB setup
- `make run` — start the HTTP server locally (needs `make db-up` + `make migrate`)
- `make build` / `make deps` — compile / fetch deps
- `./bin/coverage` — run the suite under Erlang `cover` (self-provisions its own testcontainers DB), print a per-module + total summary (lines and clauses), write `build/coverage/cobertura.xml`, and **enforce a dual gate: lines ≥ 80% and clauses ≥ 90%**
- `docker compose up --build` — full containerized stack: postgres → migrate (one-shot) → app (production Erlang shipment, `erlang:28-alpine`)

Tool versions are pinned in `.tool-versions` (Erlang 28, Gleam 1.16.0, Elixir 1.18). The runtime image's OTP **must match** the `gleam` build image's OTP (currently 28); moving to OTP 29 needs a gleam build image published on OTP 29.

gleeunit has no built-in single-test filter; the runner executes all `*_test` functions it discovers. To narrow scope while iterating, temporarily reduce the test module under edit.

### Coverage

`bin/coverage` (bash wrapper) runs `gleam test`, then `bin/coverage.escript` cover-compiles the application beams in `build/dev/erlang/notyet/ebin`, re-runs the suite via EUnit under instrumentation, and reports. The escript runs EUnit in a **separate BEAM** that never calls `notyet_test.main`, so it provisions the test DB itself (`application:ensure_all_started(testcontainers)` + `application:load(notyet)` so `code:priv_dir` resolves, then `testdb:setup()`). Two metrics: **lines** (cover's line analysis) and **clauses** (a statement/branch proxy via `calls`/clause — Erlang `cover` has no true branch coverage). Cobertura XML maps to the generated `.erl` artefacts (not the `.gleam` sources), since coverage is measured on the Erlang backend; the module/total percentages are the reliable signal. All application source is measured — only `*_test` and generated `@@` modules are excluded. **The gate is dual: lines ≥ 80% and clauses ≥ 90%** (the escript exits non-zero otherwise). The line floor sits below the clause floor on purpose: it is bounded by the irreducible side-effecting glue in `notyet:main/0` (`mist.start` + `process.sleep_forever` + supervisor/pog wiring), which cannot run under a unit test and which clause coverage — where `main/0` is a single clause — does not penalize. Coverage gaps must still be closed with tests, not by excluding code. `covertool` is a dev dependency.

### CI

`.github/workflows/ci.yml` runs four jobs on push-to-`main`/PR (OTP 28, Gleam 1.16.0, Elixir 1.18; `mix local.hex`/`local.rebar` are installed first because `gleam build` compiles the Elixir testcontainers dep chain).

- **lint** — `gleam format --check src test` + `gleam build --warnings-as-errors`
- **test** — `./bin/coverage` (self-provisions the testcontainers DB; the runner installs `inotify-tools`), then uploads `build/coverage/cobertura.xml` to Codecov (`fail_ci_if_error: false`, non-blocking)
- **sqlcheck** — `gleam run -m squirrel_db -- check` (fails if the generated SQL has drifted from `*.sql`)
- **docker** — `docker build --target runtime` (verifies the production image builds)

## Environment

All variables are **mandatory** — `notyet/config.from_env` reads, parses, and validates each, returning a typed `ConfigError`; `main()` calls it with `let assert`, so the boot still panics if any is missing or unparseable. No dev fallbacks. See `.env.example`.

- `DATABASE_URL` — pog Postgres connection URL (`postgres://…`).
- `SECRET_KEY_BASE` — wisp signing key.
- `PORT` — server port.
- `TASK_BATCH_MAX_SIZE` — flush the write buffer when it reaches this many rows.
- `TASK_BATCH_INTERVAL_MS` — flush this long after the first pending row.
- `TASK_BATCH_MAX_IN_FLIGHT` — max concurrent insert workers the coordinator spawns.
- `TASK_DB_POOL_SIZE` — pog pool size; **must be `>= TASK_BATCH_MAX_IN_FLIGHT`** (asserted at boot) or inserts serialize on connection checkout and pipelining is lost.
- `TASK_ENQUEUE_TIMEOUT_MS` — timeout for the in-memory enqueue call (small; the actor replies immediately, so this only trips if the actor is dead/overloaded → 500).

## Architecture

Gleam web service built on **wisp** (web framework: routing, middleware, request/response) served by **mist** (HTTP server), bridged by `wisp_mist.handler`. Persistence is **Postgres via `pog`**, with typed queries generated by **`squirrel`** and migrations managed by **`cigogne`**. Accepted tasks are written through an in-memory write-behind **coordinator** actor (`gleam_otp`).

Request flow:

```
mist (HTTP) → wisp_mist adapter → router.handle_request(req, ctx)
            → web.middleware → task.create → coordinator actor (enqueue, fast ack)
                                                      ↓ (async, on flush)
                                              insert worker → Postgres (batch insert)

            → web.middleware → task.read  → sql.get_task_by_idempotency_key(ctx.db)
                                          → Postgres (sync read; bypasses the coordinator)
```

- **`src/notyet.gleam`** — entrypoint. Loads config via `config.from_env(envoy.get)` (`let assert`); starts a `static_supervisor` (OneForOne) supervising the `pog` connection pool **and** the **coordinator** actor; recovers the **coordinator's** `Subject` via a named process (`"task_batch"`); builds the `Context`; wires `router.handle_request` through `wisp_mist` + `mist` (bound to `0.0.0.0` so it is reachable in a container). No business logic — the testable env parsing/validation lives in `config`.
- **`src/notyet/config.gleam`** — `AppConfig` + `ConfigError` types and `from_env(get)`, which reads every required env var, parses ints, enforces the boot invariants (batch knobs `> 0`, `pool_size >= max_in_flight`), and returns a typed error. `get` is injected (`fn(String) -> Result(String, Nil)`), so it is pure and unit-testable without touching the process environment; `main` passes `envoy.get`.
- **`src/notyet/router.gleam`** — single dispatch point. Applies `web.middleware`, then matches `wisp.path_segments(req)` + `req.method`. Pattern: `["tasks"], Post -> create`, `["tasks"], _ -> 405`, `["tasks", key], Get -> read`, `["tasks", key], _ -> 405`, `_ -> 404`.
- **`src/notyet/web.gleam`** — shared web concerns: the `Context` type (`db: pog.Connection` for the read path + `batch: Subject(batch.Message)` + `enqueue_timeout_ms: Int`, threaded to every handler) and `middleware` (method override, request logging, crash rescue, HEAD handling).
- **`src/notyet/task.gleam`** — the feature module: request type (`TaskRequest`), decoders (`task_decoder` + private `wait_for_decoder`; the delivery target is decoded by `task/target.decoder`), the `create` handler (returns `202` on enqueue, `429 + Retry-After` on shed), and the `read` handler (`200` with the resource, `404` on miss, `500` on query error) plus its private `row_to_task` row→read-model mapping.
- **`src/notyet/task/view.gleam`** — the read-model: the `Task` type and `encode` (the `GET /tasks/{key}` response body). Pure — no `sql`/`pog` import — so `encode` is unit-testable without a DB; the handler is the only persistence seam.
- **`src/notyet/task/target.gleam`** — the delivery target as a closed sum type `Target` (only `Webhook(url, method, headers, body)` so far; `Method` is the closed set `GET|POST|PUT|PATCH|DELETE`). `decoder` is the write-boundary validator (http(s) `url` with no userinfo and no NUL, `method` in-set, header names as RFC 7230 tokens, header values with no CR/LF or NUL, `body` with no NUL); `encode` is the response shape (omits `body` when absent); `to_storage`/`from_storage` map `Target` ↔ `#(target_kind, target_config)` JSONB. `from_storage` is a **structural** decoder (no business re-validation) so any row the schema CHECK admits decodes — validation lives on write, the read trusts the schema.
- **`src/notyet/task/duration.gleam`** — pure strict duration-string parser → `gleam_time` `Duration`. No wisp/json deps.
- **`src/notyet/task/status.gleam`** — `Status` state machine (`Pending`/`Delivering`/`Delivered`/`Failed`) with `to_string`/`from_string`. `Pending` is the initial state; the other states are produced by the (not-yet-built) delivery worker.
- **`src/notyet/task/record.gleam`** — `TaskRecord` (the row to persist: `id`, `idempotency_key`, `wait_for`, `target`, `visible_at`, `wait_until`, `created_at`; the `target` is serialized to the `target_kind` + `target_config` columns on insert). `visible_at` is the internal scheduler column (equals `wait_until` at creation). Dependency-free, breaking the `task`↔`batch` import cycle.
- **`src/notyet/task/batch.gleam`** — write-behind **coordinator** actor. `enqueue(subject, record, timeout)` is a fast in-memory `process.call` returning `Result(Nil, Nil)` (`Ok` → accepted, `Error` → shed). The actor buffers and on `TASK_BATCH_MAX_SIZE` rows **or** `TASK_BATCH_INTERVAL_MS` **spawns a short-lived worker** (`spawn_unlinked` + `monitor`) to run the batch upsert, then returns to accept more enqueues (pipelining). At most `TASK_BATCH_MAX_IN_FLIGHT` workers run at once; when the buffer is full **and** all slots are busy the actor sheds (`Error` → `429`). Worker completion is the monitor `Down` (one per worker on any exit), so a slot never leaks or double-frees. Intra-batch duplicate keys are absorbed by `ON CONFLICT DO NOTHING` (no app-side dedup). Failures are best-effort: logged (`wisp.log_error`) then dropped. `start_with_insert` is a test seam injecting the insert.
- **`src/notyet/task/sql.gleam`** — squirrel-generated typed query module (from `src/notyet/task/sql/*.sql`). Regenerate with `make sqlgen`. Do not hand-edit.
- **`priv/migrations/`** — cigogne migrations; **`priv/cigogne.toml`** — cigogne config (falls back to `DATABASE_URL`).

`POST /tasks` contract: requires an **`Idempotency-Key` header** that is a **UUID v4** (missing/empty/non-v4 → `422`, checked before the body; stored in canonical lowercase form so a repeat with different casing still deduplicates) and a JSON body `{"wait_for": <duration string>, "target": <target object>}` → **`202 {"status": "pending"}`** (ack-on-enqueue; no row echoed — a 202 confirms enqueue, not persistence, which happens asynchronously) when accepted into the write buffer, or **`429` + `Retry-After`** when the buffer is full and all in-flight insert slots are busy (load-shed). The task is persisted **asynchronously** via the batched write-behind path (`status = 'pending'`); a failed insert is logged and dropped (best-effort, no dead-letter). **Idempotency:** writes are deduplicated by `Idempotency-Key` (`UNIQUE` column + `ON CONFLICT DO NOTHING`); a repeat with the same key never creates a second row. A retry after a `429` is safe. Invalid/missing/non-duration `wait_for` → `422`. `target` is **required** and is a closed-sum object discriminated by `"type"`. The only type today is `"webhook"`: `{"type": "webhook", "url": <http(s) url>, "method": <GET|POST|PUT|PATCH|DELETE>, "headers"?: {<name>: <value>}, "body"?: <string>}`. Validated at the boundary: `url` is a parseable http/https URI with a non-empty host, **no userinfo** (credentials like `http://user:pass@host` are rejected, so secrets never reach storage or the outbound request the delivery worker later makes), and no NUL; `method` must be in the set; header names are RFC 7230 tokens and values carry no CR/LF (header-injection guard) or NUL; `body` is opaque but may not contain NUL (NUL cannot be stored in JSONB). `headers`/`body` are optional. The target is stored raw (not normalized) as `target_kind` + a bounded `target_config` JSONB, with a DB `CHECK` mirroring the shape as defense-in-depth; missing, invalid, or unknown-`type` `target` → `422`. Wrong method on `/tasks` → `405`. `status` is a state machine seeded at `pending` (the `tasks.status` column defaults to `'pending'` with `CHECK (status IN ('pending','delivering','delivered','failed'))`). `visible_at` (the scheduler column, internal — not exposed in any response) is initialized to `wait_until`.

`GET /tasks/{key}` contract: `{key}` is the `Idempotency-Key`, a **UUID v4** (validated and matched in canonical form; a non-v4 segment → `404` without a DB query). Returns **`200`** with the complete resource `{"id", "idempotency_key", "status", "wait_for", "wait_until", "created_at", "target"}` (timestamps RFC3339 UTC; `wait_for` is the raw duration string; `target` is the nested target object — e.g. `{"type": "webhook", "url", "method", "headers", "body"?}`, `body` present only when set; `status` ∈ `pending`|`delivering`|`delivered`|`failed`; `visible_at` is **not** exposed) when the row exists, or **`404`** when it does not. Because the write path is async, a `GET` issued right after a `202` may `404` until the row is flushed — the read path queries Postgres only (`sql.get_task_by_idempotency_key`) and never the coordinator buffer, so a miss is indistinguishable from "never existed". A query/connection error → **`500`**; wrong method on `["tasks", key]` → **`405`**. Lookup is by the `UNIQUE idempotency_key` column (0-or-1 row). The read query formats timestamps as RFC3339 via `to_char` (squirrel cannot decode `timestamptz`). `row_to_task` rebuilds the read-model from the stored row with `let assert` (UUID, status, RFC3339 timestamps, and the `target` via `target.from_storage`'s structural decoder) — total against rows the constrained schema admits.

Duration grammar (strict): `"{integer} {unit}"`, exactly one space, no surrounding/double spaces, lowercase unit, integer `> 0`, plural agreement (`1` → singular, else plural). Units (exact only): `second`/`minute`/`hour`/`day`/`week`. `month`/`year` are rejected — `gleam_time` has no exact constructor for them. Note: the integer is parsed via `int.parse`, which accepts a leading `+` and leading zeros (`"+5 minutes"`, `"05 minutes"` are valid).

Handlers re-assert their own preconditions (`wisp.require_method`, `wisp.require_json`) rather than trusting the router, so they remain correct when called directly — which the unit tests do.

## Testing conventions

- **gleeunit** is the runner; tests are public functions suffixed `_test`.
- **`wisp/simulate`** builds requests in-process (`simulate.request`, `simulate.read_body`) — no live server needed. To send a JSON body, use `simulate.string_body(json) |> request.set_header("content-type", "application/json")` (there is no `simulate.json_body(String)`; the JSON-arg variant takes a `gleam/json.Json`).
- **DB-backed tests run against a self-provisioned Postgres.** `test/testdb.gleam` `setup` starts a `postgres:18-alpine` testcontainer, sets `DATABASE_URL` in-process, and migrates via the cigogne library API; `notyet_test.main` calls it before `integration.main()` (the testcontainers runner that disables Ryuk and uses a generous per-test timeout), and the coverage escript calls it too. So `make test` needs only a Docker daemon + Elixir — no `make db-up`/`make migrate`. `test/test_helper.gleam` provides `start_pool` (pool from `DATABASE_URL`, size 1), `with_db` (TRUNCATE `tasks` then run), `count_tasks`, `dummy_connection` (an unstarted handle for router-only tests), and `broken_pool` (a started pool pointed at a non-existent DB, to drive the `500` query-error branch).
- The coordinator is tested against a live DB with **eventual** assertions (`test_helper.eventually_count` polls until the expected row count or a deadline) because persistence is async. Shed (`429`), in-flight cap, and pipelining are deterministic via a **gated insert** (`batch.start_with_insert` + an insert that signals start then sleeps to hold a slot); a **failing insert** covers the worker's best-effort log-and-drop path. Tests cover both flush triggers, draining held batches, dedup (intra-batch + across calls), shed under saturation, the in-flight cap, two-worker pipelining, and insert failure.
- Test layout mirrors `src/`. Focused unit tests per concern (`config_unit_test`, `duration_unit_test`, `decoder_unit_test`, `status_unit_test`, `view_unit_test`), DB integration tests (`sql_integration_test`, `batch_test`, `handler_test`), and a router-level integration test (`router_integration_test`).
- Development is test-driven: write the failing test, then the implementation.

## Conventions

- One feature module per route file under `src/notyet/`; keep type + decoder + encoder + handler colocated. Cross-cutting helpers (status, record, batch) live in focused `src/notyet/task/*` submodules.
- SQL is authored in `src/notyet/<feature>/sql/*.sql` (one statement per file) and turned into typed Gleam by `make sqlgen`; schema changes go through a cigogne migration (`make migrate-new`), and squirrel must be regenerated against the migrated DB.
- Commits follow Conventional Commits (`feat(scope): ...`), scoped to the layer touched (`task`, `router`, `server`, `web`, `db`).
- No compound shell commands anywhere (Bash, Makefile, Dockerfile `RUN`, compose `command:`) — one command per line.
