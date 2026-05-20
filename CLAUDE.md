# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `gleam run` — start the HTTP server (listens on `PORT`, default `8000`)
- `gleam test` — run the full gleeunit suite (every `*_test` function in `test/`)
- `gleam build` — compile
- `gleam format` — format all source; `gleam format --check` to verify in CI
- `gleam deps download` — fetch dependencies from `manifest.toml`

gleeunit has no built-in single-test filter; the runner executes all `*_test` functions it discovers. To narrow scope while iterating, temporarily reduce the test module under edit.

## Environment

- `SECRET_KEY_BASE` — wisp signing key. Falls back to a dev default if unset (do not rely on the default in production).
- `PORT` — server port. Falls back to `8000` if unset or unparseable.

## Architecture

Gleam web service built on **wisp** (web framework: routing, middleware, request/response) served by **mist** (HTTP server), bridged by `wisp_mist.handler`.

Request flow:

```
mist (HTTP) → wisp_mist adapter → router.handle_request(req, ctx)
            → web.middleware → feature handler (e.g. wait.create)
```

- **`src/notyet.gleam`** — entrypoint. Reads `SECRET_KEY_BASE`/`PORT` via `envoy`, builds the `Context`, and wires `router.handle_request` through `wisp_mist` + `mist`. No business logic here.
- **`src/notyet/router.gleam`** — single dispatch point. Applies `web.middleware`, then matches on `wisp.path_segments(req)` + `req.method`. Pattern: `["wait"], Post -> handler`, `["wait"], _ -> 405`, `_ -> 404`.
- **`src/notyet/web.gleam`** — shared web concerns: the `Context` type (currently an empty marker, threaded to every handler for future shared state) and `middleware` (method override, request logging, crash rescue, HEAD handling).
- **`src/notyet/<feature>.gleam`** — one module per feature. `wait.gleam` is the template: it owns its request type (`WaitRequest`), JSON decoder (`wait_decoder` with a `non_empty_string` combinator), response encoder (`encode_response`), and the `create` handler.

`POST /wait` contract: requires JSON body `{"wait": <non-empty string>}` → `201 {"id": <uuid v4>, "status": "waiting"}`. Invalid/empty body → `422`. Wrong method on `/wait` → `405`.

Handlers re-assert their own preconditions (`wisp.require_method`, `wisp.require_json`) rather than trusting the router, so they remain correct when called directly — which the unit tests do.

## Testing conventions

- **gleeunit** is the runner; tests are public functions suffixed `_test`.
- **`wisp/simulate`** builds requests in-process (`simulate.request`, `simulate.json_body`, `simulate.read_body`) — no live server needed.
- Test layout mirrors `src/`. Features get focused unit tests per concern (`test/notyet/wait/decoder_unit_test.gleam`, `encoder_unit_test.gleam`, `handler_test.gleam`) plus a router-level integration test (`test/notyet/router_integration_test.gleam`).
- Development is test-driven: write the failing test, then the implementation.

## Conventions

- One feature module per route file under `src/notyet/`; keep type + decoder + encoder + handler colocated.
- Commits follow Conventional Commits (`feat(scope): ...`), scoped to the layer touched (`wait`, `router`, `server`, `web`).
