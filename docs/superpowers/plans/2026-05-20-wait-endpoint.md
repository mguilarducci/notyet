# POST /wait Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a greenfield Gleam HTTP service exposing `POST /wait` that validates a JSON body `{ "wait": "<non-empty string>" }` and returns `201` with `{ "id": "<uuid v4>", "status": "waiting" }`.

**Architecture:** A single wisp/mist HTTP service, no database. Requests flow `mist -> wisp_mist handler -> router.handle_request -> web.middleware -> wait.create`. The `wait` value is validated then discarded.

**Tech Stack:** Gleam 1.16, wisp (HTTP + simulate testing), mist (server), gleam_json (encode/decode), youid (UUID v4), envoy (env vars), gleeunit (test runner).

---

## File Structure

```
gleam.toml                                   # project manifest + deps
.gitignore                                   # ignore build artifacts + .env
src/notyet.gleam                             # entrypoint: env + mist startup
src/notyet/web.gleam                         # Context + middleware
src/notyet/router.gleam                      # path/method routing
src/notyet/wait.gleam                        # WaitRequest, decoder, encoder, handler
test/notyet_test.gleam                       # gleeunit runner
test/notyet/wait/decoder_unit_test.gleam     # decoder unit tests
test/notyet/wait/encoder_unit_test.gleam     # encoder unit test
test/notyet/wait/handler_test.gleam          # handler tests (direct, via simulate)
test/notyet/router_integration_test.gleam    # routing tests (via simulate)
```

Each module has one responsibility: `wait.gleam` owns the request shape + HTTP handling for the endpoint; `router.gleam` owns dispatch; `web.gleam` owns shared HTTP infra; `notyet.gleam` owns process startup.

---

## Task 1: Scaffold project

**Files:**
- Create: `gleam.toml`
- Create: `.gitignore`
- Create: `src/notyet.gleam`
- Create: `test/notyet_test.gleam`

- [ ] **Step 1: Create `gleam.toml`**

```toml
name = "notyet"
version = "1.0.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
wisp = ">= 2.2.2 and < 3.0.0"
mist = ">= 6.0.3 and < 7.0.0"
gleam_json = ">= 3.1.0 and < 4.0.0"
gleam_http = ">= 4.3.0 and < 5.0.0"
gleam_erlang = ">= 1.3.0 and < 2.0.0"
youid = ">= 1.6.0 and < 2.0.0"
envoy = ">= 1.2.0 and < 2.0.0"

[dev_dependencies]
gleeunit = ">= 1.0.0 and < 2.0.0"
```

- [ ] **Step 2: Create `.gitignore`**

```
*.beam
*.ez
/build
erl_crash.dump
.env
```

- [ ] **Step 3: Create a minimal `src/notyet.gleam`**

This is a temporary placeholder so the project compiles; it is replaced in Task 7.

```gleam
pub fn main() -> Nil {
  Nil
}
```

- [ ] **Step 4: Create the test runner `test/notyet_test.gleam`**

```gleam
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}
```

- [ ] **Step 5: Download dependencies**

Run: `gleam deps download`
Expected: resolves and downloads packages, exits 0. A `manifest.toml` is generated.

- [ ] **Step 6: Verify the project builds and tests run**

Run: `gleam test`
Expected: compiles with no errors; gleeunit reports `0 tests, 0 failures` (or similar), exits 0.

- [ ] **Step 7: Commit**

```bash
git add gleam.toml manifest.toml .gitignore src/notyet.gleam test/notyet_test.gleam
git commit -m "chore(scaffold): init gleam project for wait endpoint"
```

---

## Task 2: `wait` request decoder

**Files:**
- Create: `src/notyet/wait.gleam`
- Test: `test/notyet/wait/decoder_unit_test.gleam`

- [ ] **Step 1: Write the failing decoder tests**

Create `test/notyet/wait/decoder_unit_test.gleam`:

```gleam
import gleam/dynamic/decode
import gleam/json
import gleam/result
import notyet/wait

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"wait\":\"foo\"}")
  assert req == wait.WaitRequest(wait: "foo")
}

pub fn empty_wait_rejected_test() {
  assert decode_json("{\"wait\":\"\"}") |> result.is_error
}

pub fn missing_wait_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"wait\":123}") |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) = decode_json("{\"wait\":\"foo\",\"extra\":\"x\"}")
  assert req.wait == "foo"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test`
Expected: compile error — `notyet/wait` module / `WaitRequest` / `wait_decoder` not found.

- [ ] **Step 3: Create `src/notyet/wait.gleam` with the decoder only**

```gleam
import gleam/dynamic/decode

pub type WaitRequest {
  WaitRequest(wait: String)
}

fn non_empty_string() -> decode.Decoder(String) {
  use s <- decode.then(decode.string)
  case s {
    "" -> decode.failure("", "non-empty string")
    _ -> decode.success(s)
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use wait <- decode.field("wait", non_empty_string())
  decode.success(WaitRequest(wait:))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: 5 decoder tests pass, exits 0.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait.gleam test/notyet/wait/decoder_unit_test.gleam
git commit -m "feat(wait): add request decoder with non-empty validation"
```

---

## Task 3: `wait` response encoder

**Files:**
- Modify: `src/notyet/wait.gleam`
- Test: `test/notyet/wait/encoder_unit_test.gleam`

- [ ] **Step 1: Write the failing encoder test**

Create `test/notyet/wait/encoder_unit_test.gleam`:

```gleam
import gleam/json
import notyet/wait

pub fn encode_response_shape_test() {
  let output = wait.encode_response("abc-123") |> json.to_string
  assert output == "{\"id\":\"abc-123\",\"status\":\"waiting\"}"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: compile error — `encode_response` not found in `notyet/wait`.

- [ ] **Step 3: Add the encoder to `src/notyet/wait.gleam`**

Add the `gleam/json` import at the top (alongside the existing `gleam/dynamic/decode` import):

```gleam
import gleam/json
```

Add this function to `src/notyet/wait.gleam`:

```gleam
pub fn encode_response(id: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("status", json.string("waiting")),
  ])
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: encoder test passes (alongside decoder tests), exits 0.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait.gleam test/notyet/wait/encoder_unit_test.gleam
git commit -m "feat(wait): add response encoder with status waiting"
```

---

## Task 4: web Context + middleware

**Files:**
- Create: `src/notyet/web.gleam`

This module is shared HTTP infrastructure. It has no standalone unit test; it is
exercised by the handler tests (Task 5) and router tests (Task 6).

- [ ] **Step 1: Create `src/notyet/web.gleam`**

```gleam
import wisp

pub type Context {
  Context
}

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)

  handle_request(req)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `gleam build`
Expected: compiles with no errors, exits 0.

- [ ] **Step 3: Commit**

```bash
git add src/notyet/web.gleam
git commit -m "feat(web): add empty Context and request middleware"
```

---

## Task 5: `wait.create` handler

**Files:**
- Modify: `src/notyet/wait.gleam`
- Test: `test/notyet/wait/handler_test.gleam`

The handler is tested directly (no router yet) by piping a simulated request into
`wait.create`.

- [ ] **Step 1: Write the failing handler tests**

Create `test/notyet/wait/handler_test.gleam`:

```gleam
import gleam/dynamic/decode
import gleam/http
import gleam/json
import notyet/wait
import notyet/web
import wisp/simulate

fn post(body_json: json.Json) {
  simulate.request(http.Post, "/wait")
  |> simulate.json_body(body_json)
  |> wait.create(web.Context)
}

pub fn valid_post_returns_201_test() {
  let response = post(json.object([#("wait", json.string("foo"))]))
  assert response.status == 201
}

pub fn response_status_field_is_waiting_test() {
  let response = post(json.object([#("wait", json.string("foo"))]))
  let assert Ok(status) =
    simulate.read_body(response)
    |> json.parse(decode.at(["status"], decode.string))
  assert status == "waiting"
}

pub fn response_id_is_non_empty_test() {
  let response = post(json.object([#("wait", json.string("foo"))]))
  let assert Ok(id) =
    simulate.read_body(response)
    |> json.parse(decode.at(["id"], decode.string))
  assert id != ""
}

pub fn empty_wait_returns_422_test() {
  let response = post(json.object([#("wait", json.string(""))]))
  assert response.status == 422
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test`
Expected: compile error — `create` not found in `notyet/wait`.

- [ ] **Step 3: Add the handler to `src/notyet/wait.gleam`**

Add these imports at the top (alongside the existing `gleam/dynamic/decode` and `gleam/json` imports):

```gleam
import gleam/http.{Post}
import notyet/web.{type Context}
import wisp.{type Request, type Response}
import youid/uuid
```

Add this function to `src/notyet/wait.gleam`:

```gleam
pub fn create(req: Request, _ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)
  use body <- wisp.require_json(req)

  case decode.run(body, wait_decoder()) {
    Error(_) -> wisp.unprocessable_content()
    Ok(_) ->
      uuid.v4_string()
      |> encode_response
      |> json.to_string
      |> wisp.json_response(201)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: 4 handler tests pass (alongside decoder + encoder tests), exits 0.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/wait.gleam test/notyet/wait/handler_test.gleam
git commit -m "feat(wait): add POST handler returning id and waiting status"
```

---

## Task 6: router + integration tests

**Files:**
- Create: `src/notyet/router.gleam`
- Test: `test/notyet/router_integration_test.gleam`

- [ ] **Step 1: Write the failing router integration tests**

Create `test/notyet/router_integration_test.gleam`:

```gleam
import gleam/http
import gleam/json
import notyet/router
import notyet/web
import wisp/simulate

pub fn post_wait_dispatches_to_handler_test() {
  let body = json.object([#("wait", json.string("foo"))])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 201
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Get, "/wait")
    |> router.handle_request(web.Context)

  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown")
    |> router.handle_request(web.Context)

  assert response.status == 404
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test`
Expected: compile error — `notyet/router` module / `handle_request` not found.

- [ ] **Step 3: Create `src/notyet/router.gleam`**

```gleam
import gleam/http.{Post}
import notyet/wait
import notyet/web.{type Context}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req)

  case wisp.path_segments(req), req.method {
    ["wait"], Post -> wait.create(req, ctx)
    ["wait"], _ -> wisp.method_not_allowed([Post])
    _, _ -> wisp.not_found()
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: 3 router tests pass (alongside all earlier tests), exits 0.

- [ ] **Step 5: Commit**

```bash
git add src/notyet/router.gleam test/notyet/router_integration_test.gleam
git commit -m "feat(router): route POST /wait with 405/404 fallbacks"
```

---

## Task 7: entrypoint wiring + smoke test

**Files:**
- Modify: `src/notyet.gleam`

- [ ] **Step 1: Replace `src/notyet.gleam` with the full entrypoint**

```gleam
import envoy
import gleam/erlang/process
import gleam/int
import mist
import notyet/router
import notyet/web
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let secret_key_base = case envoy.get("SECRET_KEY_BASE") {
    Ok(key) -> key
    Error(_) -> "dev_secret_key_base_change_me"
  }

  let port = case envoy.get("PORT") {
    Ok(p) ->
      case int.parse(p) {
        Ok(n) -> n
        Error(_) -> 8000
      }
    Error(_) -> 8000
  }

  let ctx = web.Context

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}
```

- [ ] **Step 2: Format and verify the full suite**

Run: `gleam format src test`
Then run: `gleam test`
Expected: formatting applies cleanly; all tests pass, exits 0.

- [ ] **Step 3: Smoke test the running server**

Start the server in the background:

Run: `gleam run &`
Expected: log line indicating the server listening on port 8000.

Then exercise the endpoint:

Run:
```bash
curl -s -i -X POST http://localhost:8000/wait -H "Content-Type: application/json" -d '{"wait":"foo"}'
```
Expected: `HTTP/1.1 201 Created`, body like `{"id":"<uuid>","status":"waiting"}`.

Run:
```bash
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8000/wait -H "Content-Type: application/json" -d '{"wait":""}'
```
Expected: `422`.

Run:
```bash
curl -s -o /dev/null -w "%{http_code}" -X GET http://localhost:8000/wait
```
Expected: `405`.

Stop the background server:

Run: `kill %1`

- [ ] **Step 4: Commit**

```bash
git add src/notyet.gleam
git commit -m "feat(server): wire mist entrypoint for wait endpoint"
```

---

## Verification Checklist

- `gleam test` — all unit + integration tests pass.
- `gleam run` then `curl POST /wait {"wait":"foo"}` returns 201 with `id` + `status:"waiting"`.
- Empty `wait` returns 422; non-POST `/wait` returns 405; unknown path returns 404.
- `gleam format src test` reports no changes.
