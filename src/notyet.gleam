import envoy
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import mist
import notyet/config
import notyet/router
import notyet/task/batch
import notyet/web
import pog
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(cfg) = config.from_env(envoy.get)

  let pool_name = process.new_name("db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, cfg.database_url)
  let db_config = pog.pool_size(db_config, cfg.pool_size)
  let db = pog.named_connection(pool_name)

  let batch_name = process.new_name("task_batch")
  let batch_config =
    batch.Config(
      max_size: cfg.max_size,
      interval_ms: cfg.interval_ms,
      max_in_flight: cfg.max_in_flight,
    )

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.add(batch.supervised(batch_name, db, batch_config))
    |> supervisor.start

  let batch_subject = process.named_subject(batch_name)
  let ctx =
    web.Context(
      db: db,
      batch: batch_subject,
      enqueue_timeout_ms: cfg.enqueue_timeout_ms,
    )

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(cfg.secret_key_base)
    |> mist.new
    |> mist.port(cfg.port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}
