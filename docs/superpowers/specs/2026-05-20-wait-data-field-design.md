# Design: `data` field on `POST /wait`

**Date:** 2026-05-20
**Status:** Approved (design)
**Scope:** Accept an optional arbitrary-JSON `data` field on `POST /wait`. Receive only — no storage, no echo yet.

## Goal

`POST /wait` must accept an optional `data` field holding an arbitrary JSON **object** (any nesting), e.g.:

```json
{ "for": "5 minutes", "data": { "abc": 1, "xyz": [{ "asd": false }] } }
```

Storage is the eventual purpose but explicitly **out of scope now**. The representation chosen now must be re-serializable so storage can be added later without reworking the field type.

## Decisions (locked)

- `data` is **optional**. Absent → request still valid.
- When present, `data` must be a JSON **object** (`{...}`). Present-but-not-object (array, string, number, bool, `null`) → **422**.
- Representation: **custom recursive JSON ADT** (re-serializable from day one). Chosen over `Dynamic` passthrough, which cannot be re-serialized via `gleam_json` and would force this same ADT later (rework).
- Response **does not change**: `data` is accepted but not echoed and not stored. The `JsonValue` encoder is deferred (YAGNI) until storage lands.
- Test coverage target: **100% by design** — exhaustive enumeration of every ADT variant, every `one_of` branch, every contract path. No coverage-measurement tooling added (Gleam has no turnkey coverage; out of scope).

## Architecture

New pure module `src/notyet/wait/json_value.gleam`, mirroring the `duration.gleam` pattern (pure, no wisp deps, uses only `gleam/dynamic/decode`, unit-tested in isolation).

```
router → wait.create → wisp.require_json → decode.run(body, wait_decoder)
                                              ├─ field "for"  → duration_decoder (existing)
                                              └─ field "data" → json_value.object_decoder (new, optional)
```

### Data model

```gleam
pub type JsonValue {
  JObject(dict.Dict(String, JsonValue))
  JArray(List(JsonValue))
  JString(String)
  JInt(Int)
  JFloat(Float)
  JBool(Bool)
  JNull
}
```

`JObject` holds a `dict.Dict` (not a `List` of pairs): Erlang maps don't preserve
insertion order, so `dict.to_list` is non-deterministic and `List` equality in
tests would be fragile. `Dict` equality is content-based (order-independent), and
`gleam_json`'s `json.dict` maps cleanly to it for the future encoder.

### `json_value.gleam` public surface

- `JsonValue` — the ADT above.
- `decoder() -> decode.Decoder(JsonValue)` — generic; decodes **any** JSON value. Used for nested values.
- `object_decoder() -> decode.Decoder(JsonValue)` — top-level **object only**; yields `JObject`. Non-object input fails the decoder.

### Decoder behavior

- `decoder()` = `decode.recursive` wrapping `decode.one_of`, trying in this order: **bool → int → float → string → object → array → null**.
  - `int` before `float`, `bool` before `int` — avoids wrong matches on the Erlang target.
  - object branch: `decode.dict(decode.string, decoder())` mapped to `JObject`.
  - array branch: `decode.list(decoder())` mapped to `JArray`.
  - null branch: `decode.optional(decode.dynamic)` then map `None → JNull`, `Some(_) → decode.failure`. Succeeds only on actual JSON `null`. **Nested null (`{"a": null}`) decodes to `JNull`, never 422.**
- `object_decoder()` = `decode.dict(decode.string, decoder())` mapped to `JObject`. A non-object top-level value (array/string/number/bool/null) fails → `wait.create` returns 422.

### `wait.gleam` changes

- `WaitRequest` gains `data: Option(JsonValue)`.
- `wait_decoder`:

  ```gleam
  use parsed <- decode.field("for", duration_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    json_value.object_decoder() |> decode.map(Some),
  )
  decode.success(WaitRequest(duration: parsed, data: data))
  ```

  - `optional_field` returns `None` default when `data` absent.
  - `data` present-but-not-object → `object_decoder` fails → decode error → 422.
  - `data: null` explicit → `object_decoder` fails on null → 422 (consistent with "must be object").
- `create` handler logic unchanged; `data` is parsed into `WaitRequest` but not used (not echoed, not stored).

## Contract

`POST /wait` body: `{"for": <duration string>, "data"?: <json object>}`

| Input | Result |
|-------|--------|
| `for` valid, no `data` | 201 (data = None) |
| `for` valid, `data` object (any nesting) | 201 |
| `for` valid, `data` array/string/number/bool/null | 422 |
| `for` missing/invalid | 422 (unchanged) |
| wrong method | 405 (unchanged) |

201 response shape unchanged: `{id, status, created_at, for}`.

## Testing (coverage by design)

Mirrors existing test layout. Every path enumerated:

**New `test/notyet/wait/json_value_unit_test.gleam`** — exercises every ADT variant + every decoder branch:
- `decoder()`: object (simple), nested object+array (`{"abc":1,"xyz":[{"asd":false}]}`), array, string, int, float, bool true, bool false, null, empty object `{}`, empty array `[]`, deeply nested.
- `object_decoder()`: valid object → `JObject`; rejects array, string, number, bool, null (each → decode error).

**Edit `test/notyet/wait/decoder_unit_test.gleam`** — `wait_decoder`:
- `for` + valid `data` object → `WaitRequest(_, Some(JObject(...)))`.
- `for`, no `data` → `WaitRequest(_, None)`.
- `for` + `data` wrong type (array/string/number/null) → decode error.

**Edit `test/notyet/wait/handler_test.gleam`** — `create`:
- 201 with valid `data`.
- 201 without `data`.
- 422 with `data` not an object.

**Edit `test/notyet/router_integration_test.gleam`** — one end-to-end case: `POST /wait` with `data` object → 201.

## Files

| Action | Path |
|--------|------|
| New | `src/notyet/wait/json_value.gleam` |
| Edit | `src/notyet/wait.gleam` (WaitRequest + wait_decoder) |
| New | `test/notyet/wait/json_value_unit_test.gleam` |
| Edit | `test/notyet/wait/decoder_unit_test.gleam` |
| Edit | `test/notyet/wait/handler_test.gleam` |
| Edit | `test/notyet/router_integration_test.gleam` |
| Edit | `CLAUDE.md` (document `data` in the `POST /wait` contract) |

## Out of scope

- Persistence/storage of `data`.
- Echoing `data` in the response.
- The `JsonValue` → `json.Json` encoder (added with storage).
- Coverage-measurement tooling.
