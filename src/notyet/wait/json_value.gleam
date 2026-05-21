import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option

/// A fully-decoded representation of any JSON value. Re-serializable in
/// principle (the ADT is lossless); the encoder is added with storage.
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

/// Serialize a `JsonValue` back to `gleam_json`. Inverse of `decoder()`:
/// `encode |> json.to_string |> json.parse(decoder())` round-trips losslessly.
pub fn encode(value: JsonValue) -> json.Json {
  case value {
    JObject(entries) ->
      entries
      |> dict.to_list
      |> list.map(fn(pair) { #(pair.0, encode(pair.1)) })
      |> json.object
    JArray(items) -> json.array(items, encode)
    JString(s) -> json.string(s)
    JInt(i) -> json.int(i)
    JFloat(f) -> json.float(f)
    JBool(b) -> json.bool(b)
    JNull -> json.null()
  }
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

/// Decode a JSON value that must be an object. Any non-object input
/// (array, string, number, bool, null) fails the decoder.
pub fn object_decoder() -> decode.Decoder(JsonValue) {
  decode.dict(decode.string, decoder()) |> decode.map(JObject)
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
