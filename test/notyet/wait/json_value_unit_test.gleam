import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/result
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

fn decode_object(
  input: String,
) -> Result(json_value.JsonValue, List(decode.DecodeError)) {
  let assert Ok(dyn) = json.parse(input, decode.dynamic)
    as "test payload must be valid JSON"
  decode.run(dyn, json_value.object_decoder())
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
  assert decode_value("[1,2,3]") == Ok(JArray([JInt(1), JInt(2), JInt(3)]))
}

pub fn decodes_nested_object_with_array_test() {
  let expected =
    JObject(
      dict.from_list([
        #("abc", JInt(1)),
        #("xyz", JArray([JObject(dict.from_list([#("asd", JBool(False))]))])),
      ]),
    )
  assert decode_value("{\"abc\":1,\"xyz\":[{\"asd\":false}]}") == Ok(expected)
}

pub fn decodes_nested_null_test() {
  assert decode_value("{\"a\":null}")
    == Ok(JObject(dict.from_list([#("a", JNull)])))
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

pub fn null_decoder_accepts_null_test() {
  let assert Ok(dyn) = json.parse("null", decode.dynamic)
    as "test payload must be valid JSON"
  assert decode.run(dyn, json_value.null_decoder()) == Ok(JNull)
}

pub fn null_decoder_rejects_nonnull_test() {
  let assert Ok(dyn) = json.parse("5", decode.dynamic)
    as "test payload must be valid JSON"
  assert decode.run(dyn, json_value.null_decoder()) |> result.is_error
}

// Round-trip: encode then re-decode must equal the original ADT value.
fn round_trip(value: json_value.JsonValue) -> json_value.JsonValue {
  let assert Ok(decoded) =
    value
    |> json_value.encode
    |> json.to_string
    |> json.parse(json_value.decoder())
  decoded
}

pub fn encode_string_test() {
  let v = JString("hi")
  assert round_trip(v) == v
}

pub fn encode_int_test() {
  let v = JInt(42)
  assert round_trip(v) == v
}

pub fn encode_float_test() {
  let v = JFloat(3.5)
  assert round_trip(v) == v
}

pub fn encode_bool_true_test() {
  assert round_trip(JBool(True)) == JBool(True)
}

pub fn encode_bool_false_test() {
  assert round_trip(JBool(False)) == JBool(False)
}

pub fn encode_null_test() {
  assert round_trip(JNull) == JNull
}

pub fn encode_empty_object_test() {
  let v = JObject(dict.new())
  assert round_trip(v) == v
}

pub fn encode_empty_array_test() {
  assert round_trip(JArray([])) == JArray([])
}

pub fn encode_nested_test() {
  let v =
    JObject(
      dict.from_list([
        #("abc", JInt(1)),
        #("xyz", JArray([JObject(dict.from_list([#("asd", JBool(False))]))])),
      ]),
    )
  assert round_trip(v) == v
}
