import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import pog

// Each call allocates a fresh atom via process.new_name. At ~100+ integration
// tests, switch to a shared pool started once per test process.
pub fn start_pool() -> pog.Connection {
  let assert Ok(database_url) = envoy.get("DATABASE_URL")
    as "DATABASE_URL must be set for integration tests"

  let pool_name = process.new_name("test_db_pool")

  let assert Ok(db_config) = pog.url_config(pool_name, database_url)
    as "DATABASE_URL is not a valid pog url"

  // Each test starts its own pool; leaked supervisors accumulate
  // connections against Postgres' max_connections (default 100).
  // Capping at 1 keeps us under that limit for ~100 tests.
  let db_config = pog.pool_size(db_config, 1)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.start
    as "failed to start test db pool"

  pog.named_connection(pool_name)
}

pub fn with_db(test_fn: fn(pog.Connection) -> Nil) -> Nil {
  let db = start_pool()

  let assert Ok(_) =
    "TRUNCATE waits RESTART IDENTITY CASCADE"
    |> pog.query
    |> pog.execute(db)
    as "TRUNCATE waits failed — did you run `make migrate`?"

  test_fn(db)
}

pub fn count_waits(db: pog.Connection) -> Int {
  let assert Ok(pog.Returned(_, [count])) =
    "SELECT count(*)::int FROM waits"
    |> pog.query
    |> pog.returning({
      use n <- decode.field(0, decode.int)
      decode.success(n)
    })
    |> pog.execute(db)
  count
}

// Connection handle bound to an unstarted pool name. Safe to embed in a
// web.Context for tests that never query the database (router-only tests).
pub fn dummy_connection() -> pog.Connection {
  process.new_name("dummy_unused_pool")
  |> pog.named_connection
}
