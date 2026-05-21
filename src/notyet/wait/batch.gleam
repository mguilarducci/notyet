import gleam/dict
import gleam/erlang/process.{type Subject, type Timer}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/set
import gleam/time/calendar
import gleam/time/timestamp
import notyet/wait/json_value
import notyet/wait/record.{type PersistedWait, type WaitRecord}
import notyet/wait/sql
import notyet/wait/status
import pog
import youid/uuid

/// Reply sent to a waiter once its batch commits: the canonical persisted row
/// (Ok) or failure (Error). On a dedup hit the row is the original.
pub type Ack =
  Result(PersistedWait, Nil)

pub opaque type Message {
  Enqueue(record: WaitRecord, reply: Subject(Ack))
  FlushTick
}

pub type Config {
  Config(max_size: Int, interval_ms: Int)
}

type Pending =
  #(WaitRecord, Subject(Ack))

type State {
  State(
    db: pog.Connection,
    config: Config,
    self: Subject(Message),
    pending: List(Pending),
    // Tracked explicitly so the size check is O(1) per enqueue rather than
    // `list.length(pending)` (O(n) → O(n²) per batch at large max_size).
    count: Int,
    timer: Option(Timer),
  )
}

pub fn start(
  db: pog.Connection,
  config: Config,
) -> actor.StartResult(Subject(Message)) {
  builder(db, config) |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  db: pog.Connection,
  config: Config,
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() {
    builder(db, config) |> actor.named(name) |> actor.start
  })
}

fn builder(
  db: pog.Connection,
  config: Config,
) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    actor.initialised(State(
      db: db,
      config: config,
      self: self,
      pending: [],
      count: 0,
      timer: None,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
}

pub fn enqueue_async(
  subject: Subject(Message),
  record: WaitRecord,
) -> Subject(Ack) {
  let reply = process.new_subject()
  process.send(subject, Enqueue(record, reply))
  reply
}

pub fn enqueue(
  subject: Subject(Message),
  record: WaitRecord,
  timeout_ms: Int,
) -> Ack {
  let reply = enqueue_async(subject, record)
  case process.receive(reply, timeout_ms) {
    Ok(ack) -> ack
    Error(Nil) -> Error(Nil)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    FlushTick -> flush(state)
    Enqueue(record, reply) -> {
      let was_empty = state.count == 0
      let count = state.count + 1
      let state =
        State(
          ..state,
          pending: [#(record, reply), ..state.pending],
          count: count,
        )

      let state = case was_empty {
        True ->
          State(
            ..state,
            timer: Some(process.send_after(
              state.self,
              state.config.interval_ms,
              FlushTick,
            )),
          )
        False -> state
      }

      case count >= state.config.max_size {
        True -> flush(state)
        False -> actor.continue(state)
      }
    }
  }
}

fn flush(state: State) -> actor.Next(State, Message) {
  cancel_timer(state.timer)
  case state.pending {
    [] -> actor.continue(State(..state, count: 0, timer: None))
    pending -> {
      let waiters = list.reverse(pending)
      let distinct = dedup_by_key(list.map(waiters, fn(p) { p.0 }))
      case do_insert(state.db, distinct) {
        Ok(pog.Returned(_, rows)) -> {
          let by_key = rows_by_key(rows)
          list.each(waiters, fn(p) {
            case dict.get(by_key, { p.0 }.idempotency_key) {
              Ok(persisted) -> process.send(p.1, Ok(persisted))
              Error(Nil) -> process.send(p.1, Error(Nil))
            }
          })
        }
        Error(_) -> list.each(waiters, fn(p) { process.send(p.1, Error(Nil)) })
      }
      actor.continue(State(..state, pending: [], count: 0, timer: None))
    }
  }
}

/// Keep the first record per idempotency_key (Postgres rejects ON CONFLICT
/// touching the same row twice within one statement).
fn dedup_by_key(records: List(WaitRecord)) -> List(WaitRecord) {
  let #(kept, _) =
    list.fold(records, #([], set.new()), fn(acc, r) {
      let #(kept, seen) = acc
      case set.contains(seen, r.idempotency_key) {
        True -> acc
        False -> #([r, ..kept], set.insert(seen, r.idempotency_key))
      }
    })
  list.reverse(kept)
}

fn rows_by_key(
  rows: List(sql.InsertWaitsRow),
) -> dict.Dict(String, PersistedWait) {
  list.fold(rows, dict.new(), fn(acc, row) {
    case status.from_string(row.status) {
      Ok(s) ->
        dict.insert(
          acc,
          row.idempotency_key,
          record.PersistedWait(
            id: row.id,
            activity: row.activity,
            status: s,
            created_at: row.created_at,
            wait_until: row.wait_until,
          ),
        )
      // Unreachable: the `waits.status` CHECK constraint mirrors `Status`, so a
      // persisted value always parses. Dropping the row here would (wrongly)
      // 500 a committed write — kept only to satisfy exhaustiveness.
      Error(Nil) -> acc
    }
  })
}

fn cancel_timer(timer: Option(Timer)) -> Nil {
  case timer {
    Some(t) -> {
      process.cancel_timer(t)
      Nil
    }
    None -> Nil
  }
}

fn do_insert(
  db: pog.Connection,
  records: List(WaitRecord),
) -> Result(pog.Returned(sql.InsertWaitsRow), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let activities = list.map(records, fn(r) { uuid.to_string(r.activity) })
  let keys = list.map(records, fn(r) { r.idempotency_key })
  let datas = list.map(records, fn(r) { data_string(r.data) })
  let fors = list.map(records, fn(r) { r.for_duration })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_waits(db, ids, activities, keys, datas, fors, untils, createds)
}

/// Empty string is the "no data" sentinel: the insert query maps it back to
/// SQL NULL via `NULLIF(d, '')`. Safe because no JSON object serializes to "".
fn data_string(data: Option(json_value.JsonValue)) -> String {
  case data {
    Some(value) -> value |> json_value.encode |> json.to_string
    None -> ""
  }
}

fn rfc3339(t: timestamp.Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
