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
