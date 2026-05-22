import gleam/erlang/process
import gleam/otp/actor
import gleam/time/timestamp
import notyet/task/batch
import notyet/task/record
import pog
import test_helper
import youid/uuid

fn rec() -> record.TaskRecord {
  record.TaskRecord(
    id: uuid.v4(),
    idempotency_key: uuid.v4_string(),
    wait_for: "5 minutes",
    wait_until: timestamp.system_time(),
    created_at: timestamp.system_time(),
  )
}

fn rec_with_key(key: String) -> record.TaskRecord {
  record.TaskRecord(..rec(), idempotency_key: key)
}

// An insert that signals its start on `started`, then sleeps to hold the
// in-flight slot. Lets a test deterministically observe concurrency / shedding.
fn gated_insert(started: process.Subject(Nil)) {
  fn(_db: pog.Connection, _records: List(record.TaskRecord)) {
    process.send(started, Nil)
    process.sleep(2000)
    Ok(pog.Returned(0, []))
  }
}

pub fn flush_by_size_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 3, 60_000, 4)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 3, 2000) == 3
}

pub fn flush_by_interval_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 100, 100, 4)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn multiple_batches_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 2, 200, 4)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 5, 3000) == 5
}

// max_in_flight: 1 forces serialization. The first enqueue flushes (worker
// busy); the second is HELD in the buffer (slot busy, no flush) and can only be
// flushed once `WorkerDone` frees the slot — so both rows persisting proves the
// held batch drains on WorkerDone. (A third synchronous enqueue would be shed:
// with max_size 1 the buffer holds at most one held record, and the in-memory
// calls outrun the real DB worker, so it cannot be accepted before WorkerDone.)
pub fn worker_done_drains_held_batches_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 1, 60_000, 1)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 2, 3000) == 2
}

pub fn same_key_in_one_batch_dedups_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 2, 60_000, 4)
  let key = "dup-key"
  assert batch.enqueue(subject, rec_with_key(key), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec_with_key(key), 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

// Buffer full (max_size 1) AND the only worker slot busy -> the next enqueue is
// shed with Error. The gated insert holds the slot for the whole assertion.
pub fn shed_when_saturated_test() {
  use db <- test_helper.with_db
  let started = process.new_subject()
  let assert Ok(actor.Started(_, subject)) =
    batch.start_with_insert(
      db,
      batch.Config(max_size: 1, interval_ms: 60_000, max_in_flight: 1),
      gated_insert(started),
    )
  // #1 buffers then size-flushes -> worker spawned (in_flight 1), count back to 0
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  let assert Ok(Nil) = process.receive(started, 1000)
  // #2 buffers (count 1); slot busy so no flush
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  // #3 full AND busy -> shed
  assert batch.enqueue(subject, rec(), 1000) == Error(Nil)
}

// max_in_flight: 1 means a second worker must NOT start while the first is busy.
pub fn in_flight_cap_holds_test() {
  use db <- test_helper.with_db
  let started = process.new_subject()
  let assert Ok(actor.Started(_, subject)) =
    batch.start_with_insert(
      db,
      batch.Config(max_size: 1, interval_ms: 60_000, max_in_flight: 1),
      gated_insert(started),
    )
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  // First worker started.
  let assert Ok(Nil) = process.receive(started, 1000)
  // No second start: the cap held the second batch.
  assert process.receive(started, 300) == Error(Nil)
}

// max_in_flight: 2 -> a second batch starts while the first is still in flight.
pub fn pipelining_runs_two_workers_test() {
  use db <- test_helper.with_db
  let started = process.new_subject()
  let assert Ok(actor.Started(_, subject)) =
    batch.start_with_insert(
      db,
      batch.Config(max_size: 1, interval_ms: 60_000, max_in_flight: 2),
      gated_insert(started),
    )
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  // Both workers signalled start while both are sleeping -> concurrent.
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(Nil) = process.receive(started, 1000)
  Nil
}
