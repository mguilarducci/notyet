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
  let assert Ok(max_in_flight) = read_int("WAIT_BATCH_MAX_IN_FLIGHT")
  let assert Ok(pool_size) = read_int("WAIT_DB_POOL_SIZE")
  let assert Ok(enqueue_timeout_ms) = read_int("WAIT_ENQUEUE_TIMEOUT_MS")

  // Fail fast on incoherent config rather than emitting intermittent failures.
  let assert True = max_size > 0
  let assert True = interval_ms > 0
  let assert True = max_in_flight > 0
  let assert True = enqueue_timeout_ms > 0
  // Inserts pipeline only if the pool can serve every concurrent worker; with a
  // smaller pool they serialize on connection checkout and pipelining is lost.
  let assert True = pool_size >= max_in_flight

  let pool_name = process.new_name("db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, database_url)
  let db_config = pog.pool_size(db_config, pool_size)
  let db = pog.named_connection(pool_name)

  let batch_name = process.new_name("wait_batch")
  let config =
    batch.Config(
      max_size: max_size,
      interval_ms: interval_ms,
      max_in_flight: max_in_flight,
    )

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.add(batch.supervised(batch_name, db, config))
    |> supervisor.start

  let batch_subject = process.named_subject(batch_name)
  let ctx =
    web.Context(
      db: db,
      batch: batch_subject,
      enqueue_timeout_ms: enqueue_timeout_ms,
    )

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}

fn read_int(name: String) -> Result(Int, Nil) {
  case envoy.get(name) {
    Ok(value) -> int.parse(value)
    Error(_) -> Error(Nil)
  }
}
