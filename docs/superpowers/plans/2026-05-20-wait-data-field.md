# Wait `data` Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept an optional arbitrary-JSON object `data` on `POST /wait` (receive-only — no storage, no echo).

**Architecture:** A new pure module `src/notyet/wait/json_value.gleam` defines a recursive `JsonValue` ADT plus a generic `decoder()` (any JSON) and an `object_decoder()` (top-level object only). `wait.WaitRequest` gains `data: Option(JsonValue)`, decoded via `decode.optional_field` using `object_decoder()`. The handler is otherwise unchanged.

**Tech Stack:** Gleam, `gleam/dynamic/decode` (recursive decoders), `gleam_json`, `gleam/dict`, `gleam/option`, gleeunit + `wisp/simulate`.

**Reference spec:** `docs/superpowers/specs/2026-05-20-wait-data-field-design.md`

---

## Notes for the implementer

- gleeunit runs **every** `*_test` function it finds; there is no single-test filter. "Run to verify it fails" means running the whole suite and seeing the new/edited test (or a compile error) as the failure.
- Run the suite with: `gleam test`
- Format before each commit: `gleam format`
- Decoder primitives are stdlib constants/functions confirmed present in this project's `gleam_stdlib`: `decode.string`, `decode.int`, `decode.float`, `decode.bool`, `decode.dynamic`, `decode.list`, `decode.dict`, `decode.optional`, `decode.recursive`, `decode.one_of`, `decode.then`, `decode.success`, `decode.failure`, `decode.map`, `decode.field`, `decode.optional_field`.
- `decode.dict(k, v)` yields a `dict.Dict`; a non-map (array/scalar/null) input fails it — that is how `object_decoder()` rejects non-objects.
- Erlang maps are unordered, so `JObject` wraps a `dict.Dict` (content-based equality) rather than a list of pairs.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `src/notyet/wait/json_value.gleam` | `JsonValue` ADT + `decoder()` + `object_decoder()` |
| Modify | `src/notyet/wait.gleam` | `WaitRequest.data`, `wait_decoder`, handler pattern |
| Create | `test/notyet/wait/json_value_unit_test.gleam` | Decoder unit tests, all variants/branches |
| Modify | `test/notyet/wait/decoder_unit_test.gleam` | `wait_decoder` data cases |
| Modify | `test/notyet/wait/handler_test.gleam` | HTTP-level data cases |
| Modify | `test/notyet/router_integration_test.gleam` | End-to-end data case |
| Modify | `CLAUDE.md` | Document `data` in the `POST /wait` contract |

---

## Task 1: `JsonValue` type + generic `decoder()`

**Files:**
- Create: `test/notyet/wait/json_value_unit_test.gleam`
- Create: `src/notyet/wait/json_value.gleam`

- [ ] **Step 1: Write the failing test**

Create `test/notyet/wait/json_value_unit_test.gleam`:

```gleam
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import notyet/wait/json_value.{
  JArray, JBool, JFloat, JInt, JNull, JObject, JString,
}

fn decode_value(
  input: String,
) -> Result(json_value.JsonValue, List(decode.DecodeError)) {
  let assert Ok(dyn) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(dyn, json_value.decoder())
}

pub fn decodes_string_test() {
  assert decode_value("\"hi\"") == Ok(JString("hi"))
}

pub fn decodes_int_test() {
  assert decode_value("5") == Ok(JInt(5))
}

pub fn decodes_float_test() {
  assert decode_value("1.5") == Ok(JFloat(1.5))
}

pub fn decodes_bool_true_test() {
  assert decode_value("true") == Ok(JBool(True))
}

pub fn decodes_bool_false_test() {
  assert decode_value("false") == Ok(JBool(False))
}

pub fn decodes_null_test() {
  assert decode_value("null") == Ok(JNull)
}

pub fn decodes_empty_object_test() {
  assert decode_value("{}") == Ok(JObject(dict.new()))
}

pub fn decodes_empty_array_test() {
  assert decode_value("[]") == Ok(JArray([]))
}

pub fn decodes_simple_object_test() {
  assert decode_value("{\"abc\":1}")
    == Ok(JObject(dict.from_list([#("abc", JInt(1))])))
}

pub fn decodes_array_of_scalars_test() {
  assert decode_value("[1,2,3]")
    == Ok(JArray([JInt(1), JInt(2), JInt(3)]))
}

pub fn decodes_nested_object_with_array_test() {
  let expected =
    JObject(
      dict.from_list([
        #("abc", JInt(1)),
        #(
          "xyz",
          JArray([JObject(dict.from_list([#("asd", JBool(False))]))]),
        ),
      ]),
    )
  assert decode_value("{\"abc\":1,\"xyz\":[{\"asd\":false}]}") == Ok(expected)
}

pub fn decodes_nested_null_test() {
  assert decode_value("{\"a\":null}")
    == Ok(JObject(dict.from_list([#("a", JNull)])))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — compile error, `module notyet/wait/json_value` not found.

- [ ] **Step 3: Write minimal implementation**

Create `src/notyet/wait/json_value.gleam`:

```gleam
import gleam/dict
import gleam/dynamic/decode
import gleam/option

/// A fully-decoded, re-serializable representation of any JSON value.
///
/// `JObject` wraps a `dict.Dict` because Erlang maps are unordered: a list of
/// pairs would make equality (and tests) depend on non-deterministic key order.
pub type JsonValue {
  JObject(dict.Dict(String, JsonValue))
  JArray(List(JsonValue))
  JString(String)
  JInt(Int)
  JFloat(Float)
  JBool(Bool)
  JNull
}

/// Decode any JSON value into a `JsonValue`. Used for nested values.
pub fn decoder() -> decode.Decoder(JsonValue) {
  use <- decode.recursive
  decode.one_of(decode.bool |> decode.map(JBool), [
    decode.int |> decode.map(JInt),
    decode.float |> decode.map(JFloat),
    decode.string |> decode.map(JString),
    decode.dict(decode.string, decoder()) |> decode.map(JObject),
    decode.list(decoder()) |> decode.map(JArray),
    null_decoder(),
  ])
}

/// Succeeds only on JSON `null`, producing `JNull`. `decode.optional` maps a
/// null value to `None`; anything else is `Some(_)` and fails this branch.
fn null_decoder() -> decode.Decoder(JsonValue) {
  use opt <- decode.then(decode.optional(decode.dynamic))
  case opt {
    option.None -> decode.success(JNull)
    option.Some(_) -> decode.failure(JNull, "null")
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: PASS (all `json_value_unit_test` functions, plus the existing suite).

- [ ] **Step 5: Commit**

```bash
gleam format
git add src/notyet/wait/json_value.gleam test/notyet/wait/json_value_unit_test.gleam
git commit -m "feat(wait): add recursive JsonValue type and decoder"
```

---

## Task 2: `object_decoder()` (top-level object only)

**Files:**
- Modify: `test/notyet/wait/json_value_unit_test.gleam`
- Modify: `src/notyet/wait/json_value.gleam`

- [ ] **Step 1: Write the failing test**

Append to `test/notyet/wait/json_value_unit_test.gleam`:

```gleam
import gleam/result

fn decode_object(
  input: String,
) -> Result(json_value.JsonValue, List(decode.DecodeError)) {
  let assert Ok(dyn) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(dyn, json_value.object_decoder())
}

pub fn object_decoder_accepts_object_test() {
  assert decode_object("{\"abc\":1}")
    == Ok(JObject(dict.from_list([#("abc", JInt(1))])))
}

pub fn object_decoder_accepts_empty_object_test() {
  assert decode_object("{}") == Ok(JObject(dict.new()))
}

pub fn object_decoder_rejects_array_test() {
  assert decode_object("[1,2]") |> result.is_error
}

pub fn object_decoder_rejects_string_test() {
  assert decode_object("\"x\"") |> result.is_error
}

pub fn object_decoder_rejects_number_test() {
  assert decode_object("5") |> result.is_error
}

pub fn object_decoder_rejects_bool_test() {
  assert decode_object("true") |> result.is_error
}

pub fn object_decoder_rejects_null_test() {
  assert decode_object("null") |> result.is_error
}
```

Note: place the `import gleam/result` line with the other imports at the top of the file (Gleam imports must precede definitions), not literally in the middle.

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — `json_value.object_decoder` does not exist (compile error / unknown function).

- [ ] **Step 3: Write minimal implementation**

Add to `src/notyet/wait/json_value.gleam` (after `decoder()`):

```gleam
/// Decode a JSON value that must be an object. Any non-object input
/// (array, string, number, bool, null) fails the decoder.
pub fn object_decoder() -> decode.Decoder(JsonValue) {
  decode.dict(decode.string, decoder()) |> decode.map(JObject)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
gleam format
git add src/notyet/wait/json_value.gleam test/notyet/wait/json_value_unit_test.gleam
git commit -m "feat(wait): add object-only decoder for JsonValue"
```

---

## Task 3: Add `data` field to `WaitRequest`

Changing `WaitRequest`'s shape is a breaking change touched in one task: the type, its decoder, the handler's pattern match, and the decoder tests that construct it must all change together to compile.

**Files:**
- Modify: `test/notyet/wait/decoder_unit_test.gleam`
- Modify: `src/notyet/wait.gleam:12-14` (type), `:24-27` (decoder), `:51` (handler pattern)

- [ ] **Step 1: Write the failing test**

Replace the entire contents of `test/notyet/wait/decoder_unit_test.gleam` with:

```gleam
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import notyet/wait
import notyet/wait/json_value.{JInt, JObject}

fn decode_json(
  input: String,
) -> Result(wait.WaitRequest, List(decode.DecodeError)) {
  let assert Ok(decoded) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(decoded, wait.wait_decoder())
}

pub fn valid_payload_decodes_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300), data: None)
}

pub fn invalid_duration_rejected_test() {
  assert decode_json("{\"for\":\"bogus\"}") |> result.is_error
}

pub fn empty_for_rejected_test() {
  assert decode_json("{\"for\":\"\"}") |> result.is_error
}

pub fn missing_for_rejected_test() {
  assert decode_json("{}") |> result.is_error
}

pub fn wrong_type_rejected_test() {
  assert decode_json("{\"for\":123}") |> result.is_error
}

pub fn extra_field_ignored_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\",\"extra\":\"x\"}")
  assert req == wait.WaitRequest(duration: duration.seconds(300), data: None)
}

pub fn data_object_decodes_to_some_test() {
  let assert Ok(req) =
    decode_json("{\"for\":\"5 minutes\",\"data\":{\"abc\":1}}")
  assert req
    == wait.WaitRequest(
      duration: duration.seconds(300),
      data: Some(JObject(dict.from_list([#("abc", JInt(1))]))),
    )
}

pub fn data_absent_is_none_test() {
  let assert Ok(req) = decode_json("{\"for\":\"5 minutes\"}")
  assert req.data == None
}

pub fn data_array_rejected_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"data\":[1,2]}")
    |> result.is_error
}

pub fn data_string_rejected_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"data\":\"x\"}")
    |> result.is_error
}

pub fn data_null_rejected_test() {
  assert decode_json("{\"for\":\"5 minutes\",\"data\":null}")
    |> result.is_error
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test`
Expected: FAIL — compile error: `WaitRequest` has no `data` field / record arity mismatch.

- [ ] **Step 3: Write minimal implementation**

Edit `src/notyet/wait.gleam`.

Add these imports alongside the existing ones (top of file):

```gleam
import gleam/option.{type Option, None, Some}
import notyet/wait/json_value.{type JsonValue}
```

Change the type (lines 12-14):

```gleam
pub type WaitRequest {
  WaitRequest(duration: Duration, data: Option(JsonValue))
}
```

Change `wait_decoder` (lines 24-27):

```gleam
pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use parsed <- decode.field("for", duration_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    json_value.object_decoder() |> decode.map(Some),
  )
  decode.success(WaitRequest(duration: parsed, data: data))
}
```

Change the handler's success pattern (line 51) from `Ok(WaitRequest(duration: d))` to:

```gleam
    Ok(WaitRequest(duration: d, data: _)) -> {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
gleam format
git add src/notyet/wait.gleam test/notyet/wait/decoder_unit_test.gleam
git commit -m "feat(wait): accept optional data object on WaitRequest"
```

---

## Task 4: HTTP-level `data` cases in handler test

These assert the behavior end-to-end through `wait.create` (already wired in Task 3), locking the 201/422 contract at the HTTP boundary.

**Files:**
- Modify: `test/notyet/wait/handler_test.gleam`

- [ ] **Step 1: Write the test**

Append to `test/notyet/wait/handler_test.gleam` (after the last function):

```gleam
pub fn valid_post_with_data_returns_201_test() {
  let body =
    json.object([
      #("for", json.string("5 minutes")),
      #("data", json.object([#("abc", json.int(1))])),
    ])
  let response = post(body)
  assert response.status == 201
}

pub fn post_without_data_returns_201_test() {
  let response = post(json.object([#("for", json.string("5 minutes"))]))
  assert response.status == 201
}

pub fn data_not_object_returns_422_test() {
  let body =
    json.object([
      #("for", json.string("5 minutes")),
      #("data", json.array([1, 2], json.int)),
    ])
  let response = post(body)
  assert response.status == 422
}
```

- [ ] **Step 2: Run test to verify behavior**

Run: `gleam test`
Expected: PASS (handler already implements this via Task 3; these tests characterize the HTTP boundary).

- [ ] **Step 3: Commit**

```bash
gleam format
git add test/notyet/wait/handler_test.gleam
git commit -m "test(wait): cover data field at HTTP handler boundary"
```

---

## Task 5: Router integration case

**Files:**
- Modify: `test/notyet/router_integration_test.gleam`

- [ ] **Step 1: Write the test**

Append to `test/notyet/router_integration_test.gleam`:

```gleam
pub fn post_wait_with_data_dispatches_to_handler_test() {
  let body =
    json.object([
      #("for", json.string("5 minutes")),
      #("data", json.object([#("abc", json.int(1))])),
    ])
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.json_body(body)
    |> router.handle_request(web.Context)

  assert response.status == 201
}
```

- [ ] **Step 2: Run test to verify behavior**

Run: `gleam test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
gleam format
git add test/notyet/router_integration_test.gleam
git commit -m "test(router): cover POST /wait with data field"
```

---

## Task 6: Document the contract in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the contract paragraph**

In `CLAUDE.md`, find the `POST /wait contract:` paragraph. Replace its first sentence so the body schema and `data` rules are documented. Change:

```
`POST /wait` contract: requires JSON body `{"for": <duration string>}` → `201 {"id": <uuid v4>, "status": "waiting", "created_at": <rfc3339 UTC>, "for": <rfc3339 UTC>}`
```

to:

```
`POST /wait` contract: requires JSON body `{"for": <duration string>, "data"?: <json object>}` → `201 {"id": <uuid v4>, "status": "waiting", "created_at": <rfc3339 UTC>, "for": <rfc3339 UTC>}`
```

Then add this sentence to the end of that same paragraph:

```
`data` is optional; when present it must be a JSON object (any nesting) — decoded into the recursive `JsonValue` ADT (`src/notyet/wait/json_value.gleam`) and held on `WaitRequest.data` as `Option(JsonValue)`. It is currently received only (not echoed, not stored); a non-object `data` (array/string/number/bool/null) is `422`.
```

- [ ] **Step 2: Verify the suite still passes**

Run: `gleam test`
Expected: PASS (docs-only change).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document optional data field in POST /wait contract"
```

---

## Done criteria

- `gleam test` passes with the full suite.
- `gleam format --check` is clean.
- Every `JsonValue` variant and every decoder branch is exercised by a test (Tasks 1–2).
- `data` absent / object / non-object paths are covered at decoder, handler, and router levels (Tasks 3–5).
- `CLAUDE.md` documents the `data` field (Task 6).
