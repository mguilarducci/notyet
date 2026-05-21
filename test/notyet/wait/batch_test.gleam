import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
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
    data: None,
    for_duration: "5 minutes",
    wait_until: timestamp.system_time(),
    created_at: timestamp.system_time(),
  )
}

fn rec_with_id(id: uuid.Uuid) -> record.WaitRecord {
  record.WaitRecord(..rec(), id: id)
}

pub fn flush_by_size_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 3, interval_ms: 60_000))

  let r1 = batch.enqueue_async(subject, rec())
  let r2 = batch.enqueue_async(subject, rec())
  let r3 = batch.enqueue_async(subject, rec())

  assert process.receive(r1, 5000) == Ok(Ok(Nil))
  assert process.receive(r2, 5000) == Ok(Ok(Nil))
  assert process.receive(r3, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 3
}

pub fn flush_by_interval_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 100, interval_ms: 150))

  let r = batch.enqueue_async(subject, rec())
  assert process.receive(r, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 1
}

pub fn no_flush_below_threshold_then_flush_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 3, interval_ms: 60_000))

  let r1 = batch.enqueue_async(subject, rec())
  let r2 = batch.enqueue_async(subject, rec())
  assert process.receive(r1, 300) == Error(Nil)

  let r3 = batch.enqueue_async(subject, rec())
  assert process.receive(r3, 5000) == Ok(Ok(Nil))
  assert process.receive(r1, 5000) == Ok(Ok(Nil))
  assert process.receive(r2, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 3
}

pub fn multiple_batches_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 2, interval_ms: 200))

  let replies = [
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
    batch.enqueue_async(subject, rec()),
  ]
  list.each(replies, fn(r) { assert process.receive(r, 5000) == Ok(Ok(Nil)) })
  assert test_helper.count_waits(db) == 5
}

pub fn flush_error_propagates_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 60_000))

  let id = uuid.v4()
  let r1 = batch.enqueue_async(subject, rec_with_id(id))
  assert process.receive(r1, 5000) == Ok(Ok(Nil))

  let r2 = batch.enqueue_async(subject, rec_with_id(id))
  assert process.receive(r2, 5000) == Ok(Error(Nil))
  assert test_helper.count_waits(db) == 1
}

pub fn data_persisted_as_jsonb_test() {
  use db <- test_helper.with_db
  let assert Ok(actor.Started(_, subject)) =
    batch.start(db, batch.Config(max_size: 1, interval_ms: 60_000))

  let r =
    record.WaitRecord(
      ..rec(),
      data: Some(JObject(dict.from_list([#("k", JInt(1))]))),
    )
  let reply = batch.enqueue_async(subject, r)
  assert process.receive(reply, 5000) == Ok(Ok(Nil))
  assert test_helper.count_waits(db) == 1
}
