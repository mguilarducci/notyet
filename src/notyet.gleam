import envoy
import gleam/erlang/process
import gleam/int
import mist
import notyet/router
import notyet/web
import wisp
import wisp/wisp_mist

/// wisp signing key from `SECRET_KEY_BASE`, falling back to a dev default.
/// Do not rely on the fallback in production.
pub fn read_secret_key_base() -> String {
  case envoy.get("SECRET_KEY_BASE") {
    Ok(key) -> key
    Error(_) -> "dev_secret_key_base_change_me"
  }
}

/// Server port from `PORT`, falling back to 8000 when unset or unparseable.
pub fn read_port() -> Int {
  case envoy.get("PORT") {
    Ok(p) ->
      case int.parse(p) {
        Ok(n) -> n
        Error(_) -> 8000
      }
    Error(_) -> 8000
  }
}

pub fn main() -> Nil {
  wisp.configure_logger()

  let ctx = web.Context

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(read_secret_key_base())
    |> mist.new
    |> mist.port(read_port())
    |> mist.start

  process.sleep_forever()
}
