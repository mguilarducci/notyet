import gleam/list
import notyet/config

fn getter(pairs: List(#(String, String))) -> fn(String) -> Result(String, Nil) {
  fn(name) {
    case list.key_find(pairs, name) {
      Ok(value) -> Ok(value)
      Error(_) -> Error(Nil)
    }
  }
}

fn valid_pairs() -> List(#(String, String)) {
  [
    #("DATABASE_URL", "postgres://u:p@localhost:5432/db"),
    #("SECRET_KEY_BASE", "secret"),
    #("PORT", "8000"),
    #("TASK_BATCH_MAX_SIZE", "50"),
    #("TASK_BATCH_INTERVAL_MS", "50"),
    #("TASK_BATCH_MAX_IN_FLIGHT", "8"),
    #("TASK_DB_POOL_SIZE", "10"),
    #("TASK_ENQUEUE_TIMEOUT_MS", "1000"),
  ]
}

fn without(name: String) -> fn(String) -> Result(String, Nil) {
  getter(list.filter(valid_pairs(), fn(pair) { pair.0 != name }))
}

fn override(name: String, value: String) -> fn(String) -> Result(String, Nil) {
  getter([#(name, value), ..valid_pairs()])
}

pub fn valid_config_test() {
  let assert Ok(cfg) = config.from_env(getter(valid_pairs()))
  assert cfg.database_url == "postgres://u:p@localhost:5432/db"
  assert cfg.secret_key_base == "secret"
  assert cfg.port == 8000
  assert cfg.max_size == 50
  assert cfg.interval_ms == 50
  assert cfg.max_in_flight == 8
  assert cfg.pool_size == 10
  assert cfg.enqueue_timeout_ms == 1000
}

pub fn missing_database_url_test() {
  assert config.from_env(without("DATABASE_URL"))
    == Error(config.MissingEnv("DATABASE_URL"))
}

pub fn missing_secret_key_base_test() {
  assert config.from_env(without("SECRET_KEY_BASE"))
    == Error(config.MissingEnv("SECRET_KEY_BASE"))
}

pub fn missing_port_test() {
  assert config.from_env(without("PORT")) == Error(config.MissingEnv("PORT"))
}

pub fn port_not_int_test() {
  assert config.from_env(override("PORT", "abc"))
    == Error(config.NotAnInt("PORT"))
}

pub fn max_size_non_positive_test() {
  assert config.from_env(override("TASK_BATCH_MAX_SIZE", "0"))
    == Error(config.NonPositive("TASK_BATCH_MAX_SIZE"))
}

pub fn interval_non_positive_test() {
  assert config.from_env(override("TASK_BATCH_INTERVAL_MS", "-1"))
    == Error(config.NonPositive("TASK_BATCH_INTERVAL_MS"))
}

pub fn max_in_flight_non_positive_test() {
  assert config.from_env(override("TASK_BATCH_MAX_IN_FLIGHT", "0"))
    == Error(config.NonPositive("TASK_BATCH_MAX_IN_FLIGHT"))
}

pub fn enqueue_timeout_non_positive_test() {
  assert config.from_env(override("TASK_ENQUEUE_TIMEOUT_MS", "0"))
    == Error(config.NonPositive("TASK_ENQUEUE_TIMEOUT_MS"))
}

pub fn pool_too_small_test() {
  assert config.from_env(override("TASK_DB_POOL_SIZE", "4"))
    == Error(config.PoolTooSmall(pool_size: 4, max_in_flight: 8))
}

pub fn pool_equal_max_in_flight_ok_test() {
  let assert Ok(cfg) = config.from_env(override("TASK_DB_POOL_SIZE", "8"))
  assert cfg.pool_size == 8
}
