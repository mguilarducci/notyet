import gleam/erlang/process.{type Subject, type Timer}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/time/calendar
import gleam/time/timestamp
import notyet/wait/json_value
import notyet/wait/record.{type WaitRecord}
import notyet/wait/sql
import pog
import youid/uuid

/// Reply sent to a waiter once its batch commits (Ok) or fails (Error).
pub type Ack =
  Result(Nil, Nil)

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
    timer: Option(Timer),
  )
}

/// Start an unnamed writer (used by tests). Returns the subject to send to.
pub fn start(
  db: pog.Connection,
  config: Config,
) -> actor.StartResult(Subject(Message)) {
  builder(db, config) |> actor.start
}

/// A supervised, named writer (used by the app). The parent recovers the
/// subject via `process.named_subject(name)`.
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
      timer: None,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
}

/// Enqueue without blocking; returns the reply subject to await later.
pub fn enqueue_async(
  subject: Subject(Message),
  record: WaitRecord,
) -> Subject(Ack) {
  let reply = process.new_subject()
  process.send(subject, Enqueue(record, reply))
  reply
}

/// Enqueue and block until the batch commits or `timeout_ms` elapses.
/// Commit -> Ok(Nil); flush failure or timeout -> Error(Nil).
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
      let was_empty = list.is_empty(state.pending)
      let pending = [#(record, reply), ..state.pending]
      let state = State(..state, pending: pending)

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

      case list.length(pending) >= state.config.max_size {
        True -> flush(state)
        False -> actor.continue(state)
      }
    }
  }
}

fn flush(state: State) -> actor.Next(State, Message) {
  cancel_timer(state.timer)
  case state.pending {
    [] -> actor.continue(State(..state, timer: None))
    pending -> {
      let records = list.reverse(pending)
      let ack = case do_insert(state.db, list.map(records, fn(p) { p.0 })) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(Nil)
      }
      list.each(records, fn(p) { process.send(p.1, ack) })
      actor.continue(State(..state, pending: [], timer: None))
    }
  }
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
  let datas = list.map(records, fn(r) { data_string(r.data) })
  let fors = list.map(records, fn(r) { r.for_duration })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_waits(db, ids, activities, datas, fors, untils, createds)
}

fn data_string(data: Option(json_value.JsonValue)) -> String {
  case data {
    Some(value) -> value |> json_value.encode |> json.to_string
    None -> ""
  }
}

fn rfc3339(t: timestamp.Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
