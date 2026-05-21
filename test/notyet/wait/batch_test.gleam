import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import notyet/wait/batch
import notyet/wait/json_value.{JInt, JObject}
import notyet/wait/record
import test_helper
import youid/uuid

fn rec() -> record.WaitRecord {
  record.WaitRecord(
    id: uuid.v4(),
    activity: uuid.v4(),
    idempotency_key: uuid.v4_string(),
    data: None,
    for_duration: "5 minutes",
    wait_until: timestamp.system_time(),
    created_at: timestamp.system_time(),
  )
}

fn rec_with_id(id: uuid.Uuid) -> record.WaitRecord {
  record.WaitRecord(..rec(), id: id)
}

fn rec_with_key(key: String) -> record.WaitRecord {
  record.WaitRecord(..rec(), idempotency_key: key)
}

pub fn flush_by_size_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 3, 60_000)

  let r1 = batch.enqueue_async(subject, rec())
  let r2 = batch.enqueue_async(subject, rec())
  let r3 = batch.enqueue_async(subject, rec())

  let assert Ok(Ok(_)) = process.receive(r1, 5000)
  let assert Ok(Ok(_)) = process.receive(r2, 5000)
  let assert Ok(Ok(_)) = process.receive(r3, 5000)
  assert test_helper.count_waits(db) == 3
}

pub fn flush_by_interval_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 100, 150)

  let r = batch.enqueue_async(subject, rec())
  let assert Ok(Ok(_)) = process.receive(r, 5000)
  assert test_helper.count_waits(db) == 1
}

pub fn no_flush_below_threshold_then_flush_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 3, 60_000)

  let r1 = batch.enqueue_async(subject, rec())
  let r2 = batch.enqueue_async(subject, rec())
  assert process.receive(r1, 300) == Error(Nil)

  let r3 = batch.enqueue_async(subject, rec())
  let assert Ok(Ok(_)) = process.receive(r3, 5000)
  let assert Ok(Ok(_)) = process.receive(r1, 5000)
  let assert Ok(Ok(_)) = process.receive(r2, 5000)
  assert test_helper.count_waits(db) == 3
}

pub fn multiple_batches_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 2, 200)

  let replies = [
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
  ]
  list.each(replies, fn(r) {
    let assert Ok(Ok(_)) = process.receive(r, 5000)
  })
  assert test_helper.count_waits(db) == 5
}

pub fn flush_error_propagates_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 1, 60_000)

  let id = uuid.v4()
  let r1 =
    batch.enqueue_async(
      subject,
      record.WaitRecord(..rec_with_id(id), idempotency_key: "ek-1"),
    )
  let assert Ok(Ok(_)) = process.receive(r1, 5000)

  // Same id, DISTINCT key: the second insert hits the primary-key conflict
  // (not the ON CONFLICT idempotency_key target) -> QueryError -> Error reply.
  let r2 =
    batch.enqueue_async(
      subject,
      record.WaitRecord(..rec_with_id(id), idempotency_key: "ek-2"),
    )
  assert process.receive(r2, 5000) == Ok(Error(Nil))
  assert test_helper.count_waits(db) == 1
}

pub fn data_persisted_as_jsonb_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 1, 60_000)

  let r =
    record.WaitRecord(
      ..rec(),
      data: Some(JObject(dict.from_list([#("k", JInt(1))]))),
    )
  let reply = batch.enqueue_async(subject, r)
  let assert Ok(Ok(_)) = process.receive(reply, 5000)
  assert test_helper.count_waits(db) == 1
}

pub fn same_key_in_one_batch_dedups_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 2, 60_000)

  let key = "dup-key"
  let r1 = batch.enqueue_async(subject, rec_with_key(key))
  let r2 = batch.enqueue_async(subject, rec_with_key(key))
  let assert Ok(Ok(p1)) = process.receive(r1, 5000)
  let assert Ok(Ok(p2)) = process.receive(r2, 5000)
  assert p1.id == p2.id
  assert test_helper.count_waits(db) == 1
}
