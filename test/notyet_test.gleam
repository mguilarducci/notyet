import testcontainers_gleam/integration
import testdb

pub fn main() -> Nil {
  testdb.setup()
  integration.main()
}
