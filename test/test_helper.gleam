import envoy
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/string
import notyet/task/batch
import notyet/web
import pog
import wisp
import wisp/simulate

pub const v4 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

pub const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

pub const v7 = "018f6f6e-7000-7000-8000-000000000000"

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
    "TRUNCATE tasks RESTART IDENTITY CASCADE"
    |> pog.query
    |> pog.execute(db)
    as "TRUNCATE tasks failed — did you run `make migrate`?"

  test_fn(db)
}

pub fn count_tasks(db: pog.Connection) -> Int {
  let assert Ok(pog.Returned(_, [count])) =
    "SELECT count(*)::int FROM tasks"
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

// A started pool pointed at a database that does not exist, so every query
// fails with an error rather than returning rows. Drives the handler's
// query-error (500) branch.
pub fn broken_pool() -> pog.Connection {
  let assert Ok(database_url) = envoy.get("DATABASE_URL")
    as "DATABASE_URL must be set for integration tests"
  let bad_url = string.replace(database_url, "/test", "/notyet_no_such_db")

  let pool_name = process.new_name("broken_db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, bad_url)
  let db_config = pog.pool_size(db_config, 1)

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.start
    as "failed to start broken db pool"

  pog.named_connection(pool_name)
}

pub fn start_writer(
  db: pog.Connection,
  max_size: Int,
  interval_ms: Int,
  max_in_flight: Int,
) -> process.Subject(batch.Message) {
  let assert Ok(actor.Started(_, subject)) =
    batch.start(
      db,
      batch.Config(
        max_size: max_size,
        interval_ms: interval_ms,
        max_in_flight: max_in_flight,
      ),
    )
  subject
}

pub fn writer_ctx(
  db: pog.Connection,
  max_size: Int,
  interval_ms: Int,
  max_in_flight: Int,
) -> web.Context {
  web.Context(
    db: db,
    batch: start_writer(db, max_size, interval_ms, max_in_flight),
    enqueue_timeout_ms: 1000,
  )
}

/// Poll `count_tasks` until it reaches `expected` or the deadline elapses, then
/// return the final count. Needed because the write path is async (ack-on-
/// enqueue): a fixed sleep would be flaky.
pub fn eventually_count(
  db: pog.Connection,
  expected: Int,
  deadline_ms: Int,
) -> Int {
  let n = count_tasks(db)
  case n >= expected, deadline_ms <= 0 {
    True, _ -> n
    False, True -> n
    False, False -> {
      process.sleep(10)
      eventually_count(db, expected, deadline_ms - 10)
    }
  }
}

// Build a POST /tasks request with a JSON body and an Idempotency-Key header.
pub fn keyed_request(json_body: String, key: String) -> wisp.Request {
  simulate.request(http.Post, "/tasks")
  |> simulate.string_body(json_body)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("idempotency-key", key)
}

pub fn json_field(body: String, field: String) -> String {
  let assert Ok(value) =
    json.parse(body, {
      use v <- decode.field(field, decode.string)
      decode.success(v)
    })
  value
}

pub fn json_field_missing(body: String, field: String) -> Bool {
  let result =
    json.parse(body, {
      use v <- decode.field(field, decode.optional(decode.string))
      decode.success(v)
    })
  case result {
    Ok(Some(_)) -> False
    Ok(None) -> True
    Error(_) -> True
  }
}
