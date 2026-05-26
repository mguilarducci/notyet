import gleam/dict.{type Dict}
import gleam/option.{type Option}

/// The delivery target — a closed sum type. Only `Webhook` exists this session;
/// future variants (QueuePublish, Email) are added as new arms (code change),
/// keeping every `case` exhaustive.
pub type Target {
  Webhook(
    url: String,
    method: Method,
    headers: Dict(String, String),
    body: Option(String),
  )
}

/// HTTP method for a webhook delivery. Closed set.
pub type Method {
  Get
  Post
  Put
  Patch
  Delete
}

pub fn method_to_string(method: Method) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Put -> "PUT"
    Patch -> "PATCH"
    Delete -> "DELETE"
  }
}

pub fn method_from_string(value: String) -> Result(Method, Nil) {
  case value {
    "GET" -> Ok(Get)
    "POST" -> Ok(Post)
    "PUT" -> Ok(Put)
    "PATCH" -> Ok(Patch)
    "DELETE" -> Ok(Delete)
    _ -> Error(Nil)
  }
}
