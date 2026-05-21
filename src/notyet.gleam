import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/static_supervisor as supervisor
import mist
import notyet/router
import notyet/wait/batch
import notyet/web
import pog
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(database_url) = envoy.get("DATABASE_URL")
  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")
  let assert Ok(port) = read_int("PORT")
  let assert Ok(max_size) = read_int("WAIT_BATCH_MAX_SIZE")
  let assert Ok(interval_ms) = read_int("WAIT_BATCH_INTERVAL_MS")
  let assert Ok(ack_timeout_ms) = read_int("WAIT_BATCH_ACK_TIMEOUT_MS")

  let pool_name = process.new_name("db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, database_url)
  let db = pog.named_connection(pool_name)

  let batch_name = process.new_name("wait_batch")
  let config = batch.Config(max_size: max_size, interval_ms: interval_ms)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.add(batch.supervised(batch_name, db, config))
    |> supervisor.start

  let batch_subject = process.named_subject(batch_name)
  let ctx = web.Context(batch: batch_subject, ack_timeout_ms: ack_timeout_ms)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

fn read_int(name: String) -> Result(Int, Nil) {
  case envoy.get(name) {
    Ok(value) -> int.parse(value)
    Error(_) -> Error(Nil)
  }
}
