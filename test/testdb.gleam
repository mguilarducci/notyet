//// Test database provisioning via testcontainers.
////
//// `setup` starts a postgres:18-alpine container, sets `DATABASE_URL`
//// in-process, and applies migrations via the cigogne library API. Both the
//// gleam test runner (`notyet_test.main`) and the coverage escript call it so
//// each test BEAM provisions its own database; the container is reaped when
//// the owning process exits.

import cigogne
import cigogne/config
import envoy
import gleam/int
import gleam/option
import testcontainers_gleam
import testcontainers_gleam/postgres

pub fn setup() -> Nil {
  let container =
    postgres.new()
    |> postgres.with_image("postgres:18-alpine")
    |> postgres.build

  let assert Ok(running) = testcontainers_gleam.start_container(container)
    as "failed to start postgres testcontainer (is Docker running?)"

  let port = postgres.port(running)
  let url = "postgres://test:test@localhost:" <> int.to_string(port) <> "/test"

  envoy.set("DATABASE_URL", url)

  migrate(url)
}

fn migrate(url: String) -> Nil {
  let cfg =
    config.Config(
      database: config.UrlDbConfig(url),
      migration_table: config.default_mig_table_config,
      migrations: config.MigrationsConfig(
        application_name: "notyet",
        migration_folder: option.None,
        dependencies: [],
        no_hash_check: option.None,
      ),
    )

  let assert Ok(engine) = cigogne.create_engine(cfg)
    as "cigogne create_engine failed"
  let assert Ok(_) =
    cigogne.apply_migrations(engine, cigogne.get_unapplied_migrations(engine))
    as "cigogne apply_migrations failed"
  Nil
}
