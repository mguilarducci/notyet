//// This module contains the code to run the sql queries defined in
//// `./src/notyet/task/sql`.
//// > 🐿️ This module was generated automatically using v4.6.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import pog

/// A row you get from running the `get_task_by_idempotency_key` query
/// defined in `./src/notyet/task/sql/get_task_by_idempotency_key.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetTaskByIdempotencyKeyRow {
  GetTaskByIdempotencyKeyRow(
    id: String,
    idempotency_key: String,
    status: String,
    wait_for: String,
    wait_until: String,
    created_at: String,
  )
}

/// Runs the `get_task_by_idempotency_key` query
/// defined in `./src/notyet/task/sql/get_task_by_idempotency_key.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_task_by_idempotency_key(
  db: pog.Connection,
  arg_1: String,
) -> Result(pog.Returned(GetTaskByIdempotencyKeyRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use idempotency_key <- decode.field(1, decode.string)
    use status <- decode.field(2, decode.string)
    use wait_for <- decode.field(3, decode.string)
    use wait_until <- decode.field(4, decode.string)
    use created_at <- decode.field(5, decode.string)
    decode.success(GetTaskByIdempotencyKeyRow(
      id:,
      idempotency_key:,
      status:,
      wait_for:,
      wait_until:,
      created_at:,
    ))
  }

  "SELECT
  id::text,
  idempotency_key,
  status,
  wait_for,
  to_char(wait_until AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS wait_until,
  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS created_at
FROM tasks
WHERE idempotency_key = $1;
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `insert_tasks` query
/// defined in `./src/notyet/task/sql/insert_tasks.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_tasks(
  db: pog.Connection,
  arg_1: List(String),
  arg_2: List(String),
  arg_3: List(String),
  arg_4: List(String),
  arg_5: List(String),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "INSERT INTO tasks (id, idempotency_key, wait_for, wait_until, created_at)
SELECT i::uuid, k, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[])
  AS t(i, k, f, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
"
  |> pog.query
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_1))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_2))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_3))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_4))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
