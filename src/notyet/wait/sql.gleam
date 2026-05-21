//// This module contains the code to run the sql queries defined in
//// `./src/notyet/wait/sql`.
//// > 🐿️ This module was generated automatically using v4.6.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/time/timestamp.{type Timestamp}
import pog
import youid/uuid.{type Uuid}

/// A row you get from running the `insert_waits` query
/// defined in `./src/notyet/wait/sql/insert_waits.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.6.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type InsertWaitsRow {
  InsertWaitsRow(
    id: Uuid,
    activity: Uuid,
    idempotency_key: String,
    status: String,
    created_at: Timestamp,
    wait_until: Timestamp,
  )
}

/// Runs the `insert_waits` query
/// defined in `./src/notyet/wait/sql/insert_waits.sql`.
///
/// > 🐿️ This function was generated automatically using v4.6.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_waits(
  db: pog.Connection,
  arg_1: List(String),
  arg_2: List(String),
  arg_3: List(String),
  arg_4: List(String),
  arg_5: List(String),
  arg_6: List(String),
  arg_7: List(String),
) -> Result(pog.Returned(InsertWaitsRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, uuid_decoder())
    use activity <- decode.field(1, uuid_decoder())
    use idempotency_key <- decode.field(2, decode.string)
    use status <- decode.field(3, decode.string)
    use created_at <- decode.field(4, pog.timestamp_decoder())
    use wait_until <- decode.field(5, pog.timestamp_decoder())
    decode.success(InsertWaitsRow(
      id:,
      activity:,
      idempotency_key:,
      status:,
      created_at:,
      wait_until:,
    ))
  }

  "INSERT INTO waits (id, activity, idempotency_key, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, k, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, a, k, d, f, w, c)
ON CONFLICT (idempotency_key) DO UPDATE SET id = waits.id
RETURNING
  id,
  activity,
  idempotency_key,
  status,
  created_at AT TIME ZONE 'UTC' AS created_at,
  wait_until AT TIME ZONE 'UTC' AS wait_until;
"
  |> pog.query
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_1))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_2))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_3))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_4))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_5))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_6))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

// --- Encoding/decoding utils -------------------------------------------------

/// A decoder to decode `Uuid`s coming from a Postgres query.
///
fn uuid_decoder() {
  use bit_array <- decode.then(decode.bit_array)
  case uuid.from_bit_array(bit_array) {
    Ok(uuid) -> decode.success(uuid)
    Error(_) -> decode.failure(uuid.v7(), "Uuid")
  }
}
