//// Application configuration: read every required environment variable,
//// parse and validate it, and surface a typed error rather than panicking.
////
//// `from_env` takes the environment lookup as a parameter so it is pure and
//// unit-testable without touching the real process environment; `main` injects
//// `envoy.get`. Validation mirrors the boot-time invariants the service
//// requires: the batch knobs must be positive and the pool must be at least as
//// large as the in-flight cap (or inserts serialize on connection checkout).

import gleam/int
import gleam/result

pub type AppConfig {
  AppConfig(
    database_url: String,
    secret_key_base: String,
    port: Int,
    max_size: Int,
    interval_ms: Int,
    max_in_flight: Int,
    pool_size: Int,
    enqueue_timeout_ms: Int,
  )
}

pub type ConfigError {
  MissingEnv(name: String)
  NotAnInt(name: String)
  NonPositive(name: String)
  PoolTooSmall(pool_size: Int, max_in_flight: Int)
}

pub fn from_env(
  get: fn(String) -> Result(String, Nil),
) -> Result(AppConfig, ConfigError) {
  use database_url <- result.try(string_var(get, "DATABASE_URL"))
  use secret_key_base <- result.try(string_var(get, "SECRET_KEY_BASE"))
  use port <- result.try(int_var(get, "PORT"))
  use max_size <- result.try(positive_var(get, "TASK_BATCH_MAX_SIZE"))
  use interval_ms <- result.try(positive_var(get, "TASK_BATCH_INTERVAL_MS"))
  use max_in_flight <- result.try(positive_var(get, "TASK_BATCH_MAX_IN_FLIGHT"))
  use pool_size <- result.try(int_var(get, "TASK_DB_POOL_SIZE"))
  use enqueue_timeout_ms <- result.try(positive_var(
    get,
    "TASK_ENQUEUE_TIMEOUT_MS",
  ))

  case pool_size >= max_in_flight {
    True ->
      Ok(AppConfig(
        database_url:,
        secret_key_base:,
        port:,
        max_size:,
        interval_ms:,
        max_in_flight:,
        pool_size:,
        enqueue_timeout_ms:,
      ))
    False -> Error(PoolTooSmall(pool_size:, max_in_flight:))
  }
}

fn string_var(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(String, ConfigError) {
  case get(name) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(MissingEnv(name))
  }
}

fn int_var(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(Int, ConfigError) {
  use raw <- result.try(string_var(get, name))
  case int.parse(raw) {
    Ok(n) -> Ok(n)
    Error(_) -> Error(NotAnInt(name))
  }
}

fn positive_var(
  get: fn(String) -> Result(String, Nil),
  name: String,
) -> Result(Int, ConfigError) {
  use n <- result.try(int_var(get, name))
  case n > 0 {
    True -> Ok(n)
    False -> Error(NonPositive(name))
  }
}
