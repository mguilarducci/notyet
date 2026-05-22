//// Runs squirrel against a testcontainers-provisioned, migrated Postgres.
//// `gleam run -m squirrel_db`            -> generate typed query modules
//// `gleam run -m squirrel_db -- check`   -> verify generated modules are current
//// squirrel.main reads this process's argv, so the trailing args pass through.

import squirrel
import testdb

pub fn main() -> Nil {
  testdb.setup()
  squirrel.main()
}
