# Design: POST /wait endpoint

**Date:** 2026-05-20
**Status:** Approved

## Goal

Provide an HTTP endpoint `POST /wait` that accepts a JSON body with a single
`wait` string field and responds with a JSON object containing a randomly
generated UUID v4 (`id`) and a fixed `status` of `"waiting"`.

This is a greenfield Gleam project built on the wisp/mist HTTP stack.

## API Contract

### Request

```
POST /wait
Content-Type: application/json

{ "wait": "<non-empty string>" }
```

### Success Response

```
201 Created
Content-Type: application/json

{ "id": "<uuid v4>", "status": "waiting" }
```

- `id` — a randomly generated UUID v4, serialized as a string.
- `status` — always the literal string `"waiting"`.

The submitted `wait` value is validated and then discarded. It is not stored,
echoed, or used to drive any behavior (no actual waiting/sleeping).

### Error Responses

| Case | Status |
|------|--------|
| Valid body | 201 |
| `wait` missing, wrong type, or empty string `""` | 422 Unprocessable Content |
| Body is not valid JSON / wrong content-type | handled by `wisp.require_json` (415/400) |
| `/wait` with method other than POST | 405 Method Not Allowed (`Allow: POST`) |
| Unknown path | 404 Not Found |

## Architecture

Single HTTP service, no database and no persistence:

```
mist server
  -> wisp_mist handler
    -> router.handle_request
      -> web.middleware
        -> wait.create
```

## Module Layout

```
src/notyet.gleam                            # main: read env, start mist
src/notyet/web.gleam                        # Context + middleware
src/notyet/router.gleam                     # path/method routing
src/notyet/wait.gleam                       # request type, decoder, encoder, handler
test/notyet_test.gleam                      # gleeunit runner
test/notyet/wait/decoder_unit_test.gleam    # decoder unit tests
test/notyet/router_integration_test.gleam   # routing + status tests
```

## Components

### `notyet.gleam` (entrypoint)

- Configure wisp logger.
- Read `PORT` (default 8000) and `SECRET_KEY_BASE` from the environment via
  `envoy`.
- Build an empty `web.Context`.
- Start the mist server with the wisp handler wrapping `router.handle_request`.
- `process.sleep_forever()`.

No Postgres pool, no supervisor tree (nothing to supervise yet).

### `web.gleam`

- `Context` — an empty record `Context()`. It carries no fields today, but is
  threaded through the router so future state (DB connection, config) slots in
  without restructuring.
- `middleware` — composes `wisp.method_override`, `wisp.log_request`,
  `wisp.rescue_crashes`, `wisp.handle_head`.

### `router.gleam`

```
case wisp.path_segments(req), req.method {
  ["wait"], Post -> wait.create(req, ctx)
  ["wait"], _    -> wisp.method_not_allowed([Post])
  _, _           -> wisp.not_found()
}
```

Wraps the request in `web.middleware` first.

### `wait.gleam`

- `WaitRequest(wait: String)` — decoded request type.
- `non_empty_string()` decoder — rejects `""` (mirrors reference discipline).
- `wait_decoder()` — `decode.field("wait", non_empty_string())`.
- `encode_response(id: String)` — builds
  `{ "id": id, "status": "waiting" }` via `gleam/json`.
- `create(req, ctx)` handler:
  1. `wisp.require_method(req, Post)`
  2. `wisp.require_json(req)`
  3. `decode.run(body, wait_decoder())`
     - `Error(_)` -> `wisp.unprocessable_content()` (422)
     - `Ok(_)` -> generate `uuid.v4() |> uuid.to_string`, encode, return
       `wisp.json_response(_, 201)`

## Data Flow

```
POST /wait  { "wait": "foo" }
  -> middleware
  -> router matches ["wait"], Post
  -> wait.create
  -> require_json -> decode (non-empty wait)
  -> uuid.v4() + status "waiting"
  -> json_response(201)  { "id": "<uuid v4>", "status": "waiting" }
```

## Testing

### Decoder unit tests (`test/notyet/wait/decoder_unit_test.gleam`)

- Valid payload decodes to `WaitRequest(wait: "foo")`.
- Empty `wait` (`""`) is rejected.
- Missing `wait` field is rejected.
- Wrong type (`wait` as number) is rejected.
- Extra fields are ignored.

### Router integration tests (`test/notyet/router_integration_test.gleam`)

Using `wisp/simulate`:

- `POST /wait` with valid body -> 201, response body has `status == "waiting"`
  and a parseable, non-empty `id`.
- `POST /wait` with invalid body (empty `wait`) -> 422.
- `/wait` with a non-POST method -> 405.
- Unknown route -> 404.

No Postgres integration tests and no dummy DB connection helper (no database).

## Dependencies (`gleam.toml`)

Runtime: `gleam_stdlib`, `wisp`, `mist`, `gleam_json`, `gleam_http`,
`gleam_erlang`, `youid`, `envoy`.

Dev: `gleeunit`.

## Out of Scope (YAGNI)

- Persistence / database.
- Actually waiting, sleeping, or scheduling based on the `wait` value.
- Echoing the `wait` value back in the response.
- Authentication.
- Additional endpoints.
