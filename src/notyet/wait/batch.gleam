import gleam/erlang/process.{type Subject, type Timer}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/set
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import notyet/wait/json_value
import notyet/wait/record.{type WaitRecord}
import notyet/wait/sql
import pog
import wisp
import youid/uuid

pub opaque type Message {
  // Reply: `Ok(Nil)` = accepted into the buffer (handler -> 202);
  // `Error(Nil)` = shed because the buffer is full and every in-flight slot is
  // busy (handler -> 429).
  Enqueue(record: WaitRecord, reply: Subject(Result(Nil, Nil)))
  FlushTick
  // A monitored insert worker exited. The monitor `Down` is the SINGLE
  // completion signal: it fires exactly once per worker on ANY exit (success,
  // DB-error, or crash), and monitoring an already-dead pid still fires
  // immediately (`noproc`). So a slot can neither leak (-> permanent 429) nor be
  // freed twice. The worker therefore sends nothing itself.
  // Note: the `gleam_erlang` `process.monitor` doc-comment warns a dead process
  // "will never be received", but that caveat applies to by-name monitors —
  // `erlang:monitor(process, Pid)` on a raw Pid (what's used here) does deliver
  // an immediate `noproc` Down, so spawn-then-monitor is safe.
  WorkerDone
}

pub type Config {
  Config(max_size: Int, interval_ms: Int, max_in_flight: Int)
}

/// The batch insert, injectable so tests can supply a blocking insert to drive
/// the shed / in-flight / pipelining paths deterministically. Production uses
/// `do_insert`. The return type must match `sql.insert_waits` (see Step 2).
type Insert =
  fn(pog.Connection, List(WaitRecord)) ->
    Result(pog.Returned(Nil), pog.QueryError)

type State {
  State(
    db: pog.Connection,
    config: Config,
    self: Subject(Message),
    insert: Insert,
    pending: List(WaitRecord),
    // Tracked explicitly so the size check is O(1) per enqueue rather than
    // `list.length` (O(n) -> O(n²) per batch at large max_size).
    count: Int,
    in_flight: Int,
    timer: Option(Timer),
  )
}

pub fn start(
  db: pog.Connection,
  config: Config,
) -> actor.StartResult(Subject(Message)) {
  builder(db, config, do_insert) |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  db: pog.Connection,
  config: Config,
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() {
    builder(db, config, do_insert) |> actor.named(name) |> actor.start
  })
}

/// Test seam: start a writer whose insert is supplied by the caller.
pub fn start_with_insert(
  db: pog.Connection,
  config: Config,
  insert: Insert,
) -> actor.StartResult(Subject(Message)) {
  builder(db, config, insert) |> actor.start
}

fn builder(
  db: pog.Connection,
  config: Config,
  insert: Insert,
) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    // A custom selector overwrites the default subject selector, so we must add
    // the subject ourselves, plus a catch-all monitor handler that maps every
    // worker `Down` to `WorkerDone`.
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(_down) { WorkerDone })
    actor.initialised(State(
      db: db,
      config: config,
      self: self,
      insert: insert,
      pending: [],
      count: 0,
      in_flight: 0,
      timer: None,
    ))
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
}

/// Hand a record to the coordinator. Fast in-memory call (no DB); the actor
/// always replies immediately, so a timeout means the actor is dead/overloaded
/// (rescued by wisp -> 500). `Ok(Nil)` -> 202, `Error(Nil)` -> 429.
pub fn enqueue(
  subject: Subject(Message),
  record: WaitRecord,
  timeout_ms: Int,
) -> Result(Nil, Nil) {
  process.call(subject, timeout_ms, Enqueue(record, _))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    FlushTick ->
      case state.pending, state.in_flight < state.config.max_in_flight {
        [], _ -> actor.continue(State(..state, timer: None))
        _, True -> flush(state)
        // Slots busy: drop the timer; the held buffer drains on the next
        // WorkerDone.
        _, False -> actor.continue(State(..state, timer: None))
      }

    WorkerDone -> {
      let in_flight = state.in_flight - 1
      let state = State(..state, in_flight: in_flight)
      case state.count > 0 && in_flight < state.config.max_in_flight {
        True -> flush(state)
        False -> actor.continue(state)
      }
    }

    Enqueue(record, reply) -> {
      let full = state.count >= state.config.max_size
      let busy = state.in_flight >= state.config.max_in_flight
      case full && busy {
        // Shed: do not buffer, reply Error.
        True -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
        False -> {
          process.send(reply, Ok(Nil))
          let was_empty = state.count == 0
          let count = state.count + 1
          let state =
            State(..state, pending: [record, ..state.pending], count: count)
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
          case
            count >= state.config.max_size
            && state.in_flight < state.config.max_in_flight
          {
            True -> flush(state)
            False -> actor.continue(state)
          }
        }
      }
    }
  }
}

fn flush(state: State) -> actor.Next(State, Message) {
  cancel_timer(state.timer)
  case state.pending {
    [] -> actor.continue(State(..state, count: 0, timer: None))
    pending -> {
      let records = list.reverse(pending) |> dedup_by_key
      let insert = state.insert
      let db = state.db
      // Spawn off the actor loop so the actor keeps accepting enqueues while the
      // insert runs. Unlinked so a worker crash does not take the actor down;
      // monitored so the exit still frees the slot.
      let pid =
        process.spawn_unlinked(fn() {
          case insert(db, records) {
            Ok(_) -> Nil
            Error(e) ->
              wisp.log_error(
                "wait batch insert failed ("
                <> int.to_string(list.length(records))
                <> " rows): "
                <> string.inspect(e),
              )
          }
        })
      let _ = process.monitor(pid)
      actor.continue(
        State(
          ..state,
          pending: [],
          count: 0,
          in_flight: state.in_flight + 1,
          timer: None,
        ),
      )
    }
  }
}

/// Keep the first record per idempotency_key (belt-and-suspenders; `DO NOTHING`
/// tolerates intra-batch duplicates, but de-duping keeps each batch minimal).
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
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let ids = list.map(records, fn(r) { uuid.to_string(r.id) })
  let activities = list.map(records, fn(r) { uuid.to_string(r.activity) })
  let keys = list.map(records, fn(r) { r.idempotency_key })
  let datas = list.map(records, fn(r) { data_string(r.data) })
  let fors = list.map(records, fn(r) { r.for_duration })
  let untils = list.map(records, fn(r) { rfc3339(r.wait_until) })
  let createds = list.map(records, fn(r) { rfc3339(r.created_at) })
  sql.insert_waits(db, ids, activities, keys, datas, fors, untils, createds)
}

/// Empty string is the "no data" sentinel: the insert maps it to SQL NULL via
/// `NULLIF(d, '')`. Safe because no JSON object serializes to "".
fn data_string(data: Option(json_value.JsonValue)) -> String {
  case data {
    Some(value) -> value |> json_value.encode |> json.to_string
    None -> ""
  }
}

fn rfc3339(t: timestamp.Timestamp) -> String {
  timestamp.to_rfc3339(t, calendar.utc_offset)
}
