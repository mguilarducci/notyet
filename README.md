# notyet

A small HTTP service for scheduling deferred webhook deliveries. You submit a
task with a delay and a destination URL; the task is persisted and marked for
later delivery.

Built in [Gleam](https://gleam.run) on **wisp** + **mist**, backed by
**Postgres** (`pog` + `squirrel` + `cigogne`). Accepted tasks are buffered
through an in-memory write-behind coordinator actor and flushed to the database
in batches.

## API

### `POST /tasks`

Requires an `Idempotency-Key` header (UUID v4) and a JSON body:

```json
{ "wait_for": "5 minutes", "destination": "https://example.com/hook" }
```

- `202 { "status": "pending" }` — accepted (persisted asynchronously)
- `429` + `Retry-After` — write buffer full (load-shed; safe to retry)
- `422` — missing/invalid idempotency key, `wait_for`, or `destination`
- `405` — wrong method

`wait_for` grammar: `"<integer> <unit>"`, one space, integer `> 0`, units
`second`/`minute`/`hour`/`day`/`week` (plural-agreed). `destination` must be a
parseable `http`/`https` URL with a non-empty host and no userinfo.

Writes are deduplicated by `Idempotency-Key`, so a repeat never creates a
second row.

### `GET /tasks/{key}`

`{key}` is the `Idempotency-Key` (UUID v4).

- `200` — the task resource (`id`, `idempotency_key`, `status`, `wait_for`,
  `wait_until`, `created_at`, `destination`)
- `404` — no such task (or not yet flushed — the write path is async)
- `500` — query error

`status` ∈ `pending` | `delivering` | `delivered` | `failed`.

## Development

Common flows are wrapped in the `Makefile` (loads `.env`). DB-backed targets
self-provision a throwaway `postgres:18-alpine` via testcontainers, so they
need only a running Docker daemon and Elixir.

```sh
make test       # run the full suite (self-provisions the test DB)
make run        # start the HTTP server locally (needs make db-up + make migrate)
make db-up      # start the dev Postgres container
make migrate    # apply pending migrations
make build      # compile
```

Coverage gate: lines ≥ 80%, clauses ≥ 90% (`./bin/coverage`).

Tool versions are pinned in `.tool-versions` (Erlang 28, Gleam 1.16.0,
Elixir 1.18). See `CLAUDE.md` for the full architecture and conventions.

## License

[MIT](LICENSE)
