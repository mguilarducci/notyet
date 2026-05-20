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
