import gleam/result
import notyet/task/target

pub fn method_to_string_test() {
  assert target.method_to_string(target.Get) == "GET"
  assert target.method_to_string(target.Post) == "POST"
  assert target.method_to_string(target.Put) == "PUT"
  assert target.method_to_string(target.Patch) == "PATCH"
  assert target.method_to_string(target.Delete) == "DELETE"
}

pub fn method_from_string_roundtrip_test() {
  assert target.method_from_string("GET") == Ok(target.Get)
  assert target.method_from_string("POST") == Ok(target.Post)
  assert target.method_from_string("PUT") == Ok(target.Put)
  assert target.method_from_string("PATCH") == Ok(target.Patch)
  assert target.method_from_string("DELETE") == Ok(target.Delete)
}

pub fn method_from_string_unknown_test() {
  assert result.is_error(target.method_from_string("TRACE"))
  assert result.is_error(target.method_from_string("post"))
}
