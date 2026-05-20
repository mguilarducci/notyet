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
