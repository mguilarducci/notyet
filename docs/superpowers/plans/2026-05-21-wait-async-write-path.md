# Async Write Path for `POST /wait` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the `POST /wait` write path for very high write load: ack-on-enqueue (`202 Accepted`), the batch actor becomes a coordinator that spawns inserts off its own loop (pipelining), with bounded in-flight concurrency and `429` load-shedding.

**Architecture:** The HTTP handler validates synchronously, mints a `WaitRecord`, and hands it to the coordinator actor via a fast in-memory `process.call`. The actor buffers, and on a size/interval trigger **spawns a short-lived worker process** to run the batch `INSERT … unnest … ON CONFLICT DO NOTHING`, then immediately returns to accept more work. At most `WAIT_BATCH_MAX_IN_FLIGHT` workers run concurrently; when the buffer is full **and** all worker slots are busy, the actor sheds (replies `Error` → handler `429 + Retry-After`). Worker completion is signalled by a **process monitor `Down`** (fires exactly once per worker on any exit — success, DB-error, or crash), so an `in_flight` slot can never leak (no permanent `429`) nor be double-freed. Failures are best-effort: logged then dropped. No row is returned in the `202`.

**Tech Stack:** Gleam, `gleam_otp` 1.2 (actor + supervision), `gleam_erlang` 1.3 (process, monitor, selector), `wisp`/`mist`, `pog` 4.1 (Postgres pool), `squirrel` (typed SQL codegen), `cigogne` (migrations).

**Reference (design + rationale):** `docs/superpowers/specs/2026-05-21-wait-async-write-path-design.md`.

---

## File Structure

| Action | Path | Responsibility |
|---|---|---|
| Edit | `priv/migrations/20260521004749-create_waits.sql` | `status` default `'accepted'`, CHECK `('accepted','waiting')` |
| Edit | `src/notyet/wait/status.gleam` | rename `Received` → `Accepted` |
| Edit | `src/notyet/wait/sql/insert_waits.sql` | `ON CONFLICT DO NOTHING`, no `RETURNING` |
| Regen | `src/notyet/wait/sql.gleam` | `make sqlgen` (do not hand-edit) |
| Edit | `src/notyet/wait/record.gleam` | remove `PersistedWait` |
| Rewrite | `src/notyet/wait/batch.gleam` | coordinator + spawn + monitor-completion + in-flight cap + shed; insert seam |
| Edit | `src/notyet/wait.gleam` | `create` → `202`/`429`; drop `encode_response` |
| Edit | `src/notyet/web.gleam` | `Context.enqueue_timeout_ms` (was `ack_timeout_ms`) |
| Edit | `src/notyet.gleam` | new env, pool size, `pool_size >= max_in_flight` assert |
| Edit | `test/test_helper.gleam` | `start_writer`/`writer_ctx` add `max_in_flight`/`enqueue_timeout_ms`; `eventually_count` |
| Rewrite | `test/notyet/wait/batch_test.gleam` | async assertions, shed, pipelining, in-flight cap, dedup |
| Rewrite | `test/notyet/wait/handler_test.gleam` | `202`/`429`/`422`, eventual persistence, retry dedup |
| Rewrite | `test/notyet/wait/sql_integration_test.gleam` | no `RETURNING` rows; `DO NOTHING` dedup |
| Edit | `test/notyet/router_integration_test.gleam` | `202` + eventual persistence |
| Delete | `test/notyet/wait/encoder_unit_test.gleam` | `encode_response` is removed |
| Edit | `.env`, `.env.example` | new vars; drop `WAIT_BATCH_ACK_TIMEOUT_MS` |
| Edit | `CLAUDE.md` | contract + env docs |

---

## Important sequencing note (read first)

Gleam compiles the whole program; a dangling type/reference anywhere fails `gleam test` entirely. The async rewrite changes `batch.enqueue`'s return type, which ripples through `wait` → `web` → `notyet` and every batch/handler/router test **at once**. Those changes therefore live in **one atomic task (Task 2)** — its sub-steps will not compile until all are landed; verify and commit only at the end of Task 2.

Task 1 (status rename) is isolated and stays green on its own. Task 3 is docs.

**Preconditions for every DB-backed step:** Postgres up and migrated. After editing the migration (Task 1) recreate the dev DB. `make sqlgen` (Task 2) needs a **live, migrated** DB because squirrel introspects it.

---

## Task 1: Rename status `received` → `accepted`

The `202` response and the persisted row should share one status name. This task is self-contained and ends green.

**Files:**
- Modify: `src/notyet/wait/status.gleam`
- Modify: `priv/migrations/20260521004749-create_waits.sql`
- Modify: `test/notyet/wait/encoder_unit_test.gleam`
- Modify: `test/notyet/wait/handler_test.gleam:78`
- Modify: `test/notyet/router_integration_test.gleam:35`

- [ ] **Step 1: Edit the state machine**

Replace the full contents of `src/notyet/wait/status.gleam`:

```gleam
/// Lifecycle state of a wait. `Accepted` is the initial state set at creation
/// (the `202 Accepted` ack and the persisted row share this name). `Waiting` is
/// a later state; nothing transitions to it yet (out of scope).
pub type Status {
  Accepted
  Waiting
}

pub fn to_string(status: Status) -> String {
  case status {
    Accepted -> "accepted"
    Waiting -> "waiting"
  }
}

pub fn from_string(value: String) -> Result(Status, Nil) {
  case value {
    "accepted" -> Ok(Accepted)
    "waiting" -> Ok(Waiting)
    _ -> Error(Nil)
  }
}
```

- [ ] **Step 2: Edit the migration**

In `priv/migrations/20260521004749-create_waits.sql`, change the `status` column line:

```sql
    status          TEXT NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted', 'waiting')),
```

- [ ] **Step 3: Update the two tests that assert the literal status, and the encoder unit test**

`test/notyet/wait/handler_test.gleam` line 78 — change `"received"` to `"accepted"`:

```gleam
  assert test_helper.json_field(body, "status") == "accepted"
```

`test/notyet/router_integration_test.gleam` line 35 — change `"received"` to `"accepted"`:

```gleam
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "accepted"
```

`test/notyet/wait/encoder_unit_test.gleam` — change `status.Received` → `status.Accepted` (line 22) and `"\"status\":\"received\""` → `"\"status\":\"accepted\""` (line 32):

```gleam
      status: status.Accepted,
```
```gleam
  assert string.contains(output, "\"status\":\"accepted\"")
```

- [ ] **Step 4: Recreate the dev DB so the new CHECK/default apply**

Run each on its own line (no compound commands):

```bash
docker compose down -v
```
```bash
make db-up
```
```bash
make migrate
```

- [ ] **Step 5: Run the suite — expect green**

```bash
make test
```
Expected: PASS (all existing tests; status now `accepted` everywhere).

- [ ] **Step 6: Commit**

```bash
git add src/notyet/wait/status.gleam priv/migrations/20260521004749-create_waits.sql test/notyet/wait/encoder_unit_test.gleam test/notyet/wait/handler_test.gleam test/notyet/router_integration_test.gleam
```
```bash
git commit -m "refactor(wait): rename status received -> accepted"
```

---

## Task 2: Async write-path core (single atomic compile unit)

> Do **all** sub-steps before running `gleam` or committing. Intermediate states will not compile (the `batch.enqueue` signature change ripples through the codebase). One verification + one commit at the end.

**Files:** `src/notyet/wait/sql/insert_waits.sql`, `src/notyet/wait/sql.gleam` (regen), `src/notyet/wait/record.gleam`, `src/notyet/wait/batch.gleam`, `src/notyet/wait.gleam`, `src/notyet/web.gleam`, `src/notyet.gleam`, `test/test_helper.gleam`, `test/notyet/wait/batch_test.gleam`, `test/notyet/wait/handler_test.gleam`, `test/notyet/wait/sql_integration_test.gleam`, `test/notyet/router_integration_test.gleam`, delete `test/notyet/wait/encoder_unit_test.gleam`, `.env`, `.env.example`.

- [ ] **Step 1: Simplify the insert SQL to `DO NOTHING`, no `RETURNING`**

Replace the full contents of `src/notyet/wait/sql/insert_waits.sql`:

```sql
INSERT INTO waits (id, activity, idempotency_key, data, for_duration, wait_until, created_at)
SELECT i::uuid, a::uuid, k, NULLIF(d, '')::jsonb, f, w::timestamptz, c::timestamptz
FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[])
  AS t(i, a, k, d, f, w, c)
ON CONFLICT (idempotency_key) DO NOTHING;
```

- [ ] **Step 2: Regenerate the typed query module**

The DB must be up + migrated (done in Task 1).

```bash
make sqlgen
```

**Verify the regenerated `src/notyet/wait/sql.gleam`:** with no `RETURNING`, squirrel emits `insert_waits` returning `Result(pog.Returned(Nil), pog.QueryError)` and removes `InsertWaitsRow`. The function still takes the seven `List(String)` parameters. If squirrel's emitted return type differs from `pog.Returned(Nil)`, use whatever it generated in the `Insert` type alias (Step 4) and in `do_insert`'s signature — they must match `sql.insert_waits` exactly.

- [ ] **Step 3: Remove `PersistedWait` from the record module**

Replace the full contents of `src/notyet/wait/record.gleam`:

```gleam
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}
import notyet/wait/json_value.{type JsonValue}
import youid/uuid.{type Uuid}

/// A fully-formed wait ready to persist. Built by the handler (id + timestamps
/// minted app-side) and consumed by the batch writer. There is no longer a
/// returned-row type: the write path is fire-and-forget (no row in the 202).
pub type WaitRecord {
  WaitRecord(
    id: Uuid,
    activity: Uuid,
    idempotency_key: String,
    data: Option(JsonValue),
    for_duration: String,
    wait_until: Timestamp,
    created_at: Timestamp,
  )
}
```

- [ ] **Step 4: Rewrite the coordinator actor**

Replace the full contents of `src/notyet/wait/batch.gleam`:

```gleam
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
```

- [ ] **Step 5: Update `web.Context`**

Replace the full contents of `src/notyet/web.gleam`:

```gleam
import gleam/erlang/process
import notyet/wait/batch
import wisp

pub type Context {
  Context(batch: process.Subject(batch.Message), enqueue_timeout_ms: Int)
}

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  handle_request(req)
}
```

- [ ] **Step 6: Rewrite the `create` handler (drop `encode_response`)**

In `src/notyet/wait.gleam`: remove the `encode_response` function (lines 67-81), remove the now-unused imports `gleam/time/calendar` and `notyet/wait/status`, and replace the `create` function. Final file:

```gleam
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import notyet/wait/batch
import notyet/wait/duration as duration_parser
import notyet/wait/json_value.{type JsonValue}
import notyet/wait/record
import notyet/web.{type Context}
import wisp.{type Request, type Response}
import youid/uuid.{type Uuid}

const idempotency_header = "idempotency-key"

pub type WaitRequest {
  WaitRequest(
    duration: Duration,
    raw_for: String,
    activity: Uuid,
    data: Option(JsonValue),
  )
}

/// Decodes the "for" field into both the parsed duration and its raw string.
fn for_decoder() -> decode.Decoder(#(Duration, String)) {
  use s <- decode.then(decode.string)
  case duration_parser.parse(s) {
    Ok(d) -> decode.success(#(d, s))
    Error(_) -> decode.failure(#(duration.empty, ""), "valid duration string")
  }
}

/// Decodes "activity" as a strict UUID v4. Non-string, non-UUID, or non-v4 fail.
fn activity_decoder() -> decode.Decoder(Uuid) {
  use s <- decode.then(decode.string)
  case uuid.from_string(s) {
    Ok(u) ->
      case uuid.version(u) == uuid.V4 {
        True -> decode.success(u)
        False -> decode.failure(uuid.v4(), "activity must be a UUID v4")
      }
    Error(_) -> decode.failure(uuid.v4(), "activity must be a UUID v4")
  }
}

pub fn wait_decoder() -> decode.Decoder(WaitRequest) {
  use parsed <- decode.field("for", for_decoder())
  use activity <- decode.field("activity", activity_decoder())
  use data <- decode.optional_field(
    "data",
    None,
    json_value.object_decoder() |> decode.map(Some),
  )
  decode.success(WaitRequest(
    duration: parsed.0,
    raw_for: parsed.1,
    activity: activity,
    data: data,
  ))
}

pub fn create(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, Post)

  case request.get_header(req, idempotency_header) {
    Error(_) -> wisp.unprocessable_content()
    Ok("") -> wisp.unprocessable_content()
    Ok(key) -> {
      use body <- wisp.require_json(req)
      case decode.run(body, wait_decoder()) {
        Error(_) -> wisp.unprocessable_content()
        Ok(wr) -> {
          let now = timestamp.system_time()
          let row =
            record.WaitRecord(
              id: uuid.v4(),
              activity: wr.activity,
              idempotency_key: key,
              data: wr.data,
              for_duration: wr.raw_for,
              wait_until: timestamp.add(now, wr.duration),
              created_at: now,
            )
          case batch.enqueue(ctx.batch, row, ctx.enqueue_timeout_ms) {
            Ok(_) ->
              json.object([#("status", json.string("accepted"))])
              |> json.to_string
              |> wisp.json_response(202)
            // Shed: real client demand exceeded admission. 429 + Retry-After
            // tells the client to back off; the Idempotency-Key makes the
            // retry safe (it never creates a second row).
            Error(_) ->
              wisp.response(429)
              |> wisp.set_header("retry-after", "1")
          }
        }
      }
    }
  }
}
```

- [ ] **Step 7: Wire new env + pool size in the entrypoint**

Replace the body of `main()` in `src/notyet.gleam` (keep `read_int` as-is). Final file:

```gleam
import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/static_supervisor as supervisor
import mist
import notyet/router
import notyet/wait/batch
import notyet/web
import pog
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  wisp.configure_logger()

  let assert Ok(database_url) = envoy.get("DATABASE_URL")
  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")
  let assert Ok(port) = read_int("PORT")
  let assert Ok(max_size) = read_int("WAIT_BATCH_MAX_SIZE")
  let assert Ok(interval_ms) = read_int("WAIT_BATCH_INTERVAL_MS")
  let assert Ok(max_in_flight) = read_int("WAIT_BATCH_MAX_IN_FLIGHT")
  let assert Ok(pool_size) = read_int("WAIT_DB_POOL_SIZE")
  let assert Ok(enqueue_timeout_ms) = read_int("WAIT_ENQUEUE_TIMEOUT_MS")

  // Fail fast on incoherent config rather than emitting intermittent failures.
  let assert True = max_size > 0
  let assert True = interval_ms > 0
  let assert True = max_in_flight > 0
  let assert True = enqueue_timeout_ms > 0
  // Inserts pipeline only if the pool can serve every concurrent worker; with a
  // smaller pool they serialize on connection checkout and pipelining is lost.
  let assert True = pool_size >= max_in_flight

  let pool_name = process.new_name("db_pool")
  let assert Ok(db_config) = pog.url_config(pool_name, database_url)
  let db_config = pog.pool_size(db_config, pool_size)
  let db = pog.named_connection(pool_name)

  let batch_name = process.new_name("wait_batch")
  let config =
    batch.Config(
      max_size: max_size,
      interval_ms: interval_ms,
      max_in_flight: max_in_flight,
    )

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(pog.supervised(db_config))
    |> supervisor.add(batch.supervised(batch_name, db, config))
    |> supervisor.start

  let batch_subject = process.named_subject(batch_name)
  let ctx =
    web.Context(batch: batch_subject, enqueue_timeout_ms: enqueue_timeout_ms)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start

  process.sleep_forever()
}

fn read_int(name: String) -> Result(Int, Nil) {
  case envoy.get(name) {
    Ok(value) -> int.parse(value)
    Error(_) -> Error(Nil)
  }
}
```

- [ ] **Step 8: Update test helpers**

In `test/test_helper.gleam`: add `gleam/erlang/process` is already imported. Replace `start_writer`/`writer_ctx` and add `eventually_count`. Final state of those helpers (leave `start_pool`, `with_db`, `count_waits`, `dummy_connection`, `keyed_request`, `json_field`, and the `v4`/`v7` consts unchanged):

```gleam
pub fn start_writer(
  db: pog.Connection,
  max_size: Int,
  interval_ms: Int,
  max_in_flight: Int,
) -> process.Subject(batch.Message) {
  let assert Ok(actor.Started(_, subject)) =
    batch.start(
      db,
      batch.Config(
        max_size: max_size,
        interval_ms: interval_ms,
        max_in_flight: max_in_flight,
      ),
    )
  subject
}

pub fn writer_ctx(
  db: pog.Connection,
  max_size: Int,
  interval_ms: Int,
  max_in_flight: Int,
) -> web.Context {
  web.Context(
    batch: start_writer(db, max_size, interval_ms, max_in_flight),
    enqueue_timeout_ms: 1000,
  )
}

/// Poll `count_waits` until it reaches `expected` or the deadline elapses, then
/// return the final count. Needed because the write path is async (ack-on-
/// enqueue): a fixed sleep would be flaky.
pub fn eventually_count(
  db: pog.Connection,
  expected: Int,
  deadline_ms: Int,
) -> Int {
  let n = count_waits(db)
  case n >= expected, deadline_ms <= 0 {
    True, _ -> n
    False, True -> n
    False, False -> {
      process.sleep(10)
      eventually_count(db, expected, deadline_ms - 10)
    }
  }
}
```

- [ ] **Step 9: Delete the encoder unit test**

`encode_response` no longer exists.

```bash
git rm test/notyet/wait/encoder_unit_test.gleam
```

- [ ] **Step 10: Rewrite the batch tests**

Replace the full contents of `test/notyet/wait/batch_test.gleam`:

```gleam
import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/time/timestamp
import notyet/wait/batch
import notyet/wait/json_value.{JInt, JObject}
import notyet/wait/record
import pog
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

fn rec_with_key(key: String) -> record.WaitRecord {
  record.WaitRecord(..rec(), idempotency_key: key)
}

// An insert that signals its start on `started`, then sleeps to hold the
// in-flight slot. Lets a test deterministically observe concurrency / shedding.
fn gated_insert(started: process.Subject(Nil)) {
  fn(_db: pog.Connection, _records: List(record.WaitRecord)) {
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

// max_in_flight: 1 forces serialization. Each held batch can only drain when a
// WorkerDone frees the slot, so reaching the full count proves draining works.
pub fn worker_done_drains_held_batches_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 1, 60_000, 1)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert batch.enqueue(subject, rec(), 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 3, 3000) == 3
}

pub fn data_persisted_as_jsonb_test() {
  use db <- test_helper.with_db
  let subject = test_helper.start_writer(db, 1, 60_000, 4)
  let r =
    record.WaitRecord(
      ..rec(),
      data: Some(JObject(dict.from_list([#("k", JInt(1))]))),
    )
  assert batch.enqueue(subject, r, 1000) == Ok(Nil)
  assert test_helper.eventually_count(db, 1, 2000) == 1
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
}
```

- [ ] **Step 11: Rewrite the handler tests**

Replace the full contents of `test/notyet/wait/handler_test.gleam`:

```gleam
import gleam/http
import gleam/http/request
import notyet/wait
import test_helper
import wisp/simulate

fn ctx(db) {
  test_helper.writer_ctx(db, 1, 200, 4)
}

pub fn create_accepts_and_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-202",
    )
    |> wait.create(ctx(db))
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "accepted"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_with_data_persists_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"1 hour\",\"activity\":\""
        <> test_helper.v4
        <> "\",\"data\":{\"k\":1}}",
      "k-data",
    )
    |> wait.create(ctx(db))
  assert response.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}

pub fn create_missing_activity_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request("{\"for\":\"5 minutes\"}", "k-missing-activity")
    |> wait.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn create_non_v4_activity_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v7 <> "\"}",
      "k-v7",
    )
    |> wait.create(ctx(db))
  assert response.status == 422
}

pub fn create_bad_for_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 banana\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-bad-for",
    )
    |> wait.create(ctx(db))
  assert response.status == 422
}

pub fn missing_idempotency_key_422_test() {
  use db <- test_helper.with_db
  // No Idempotency-Key header -> 422 before the body is even decoded.
  let response =
    simulate.request(http.Post, "/wait")
    |> simulate.string_body(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
    )
    |> request.set_header("content-type", "application/json")
    |> wait.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn empty_idempotency_key_422_test() {
  use db <- test_helper.with_db
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "",
    )
    |> wait.create(ctx(db))
  assert response.status == 422
  assert test_helper.count_waits(db) == 0
}

pub fn retry_same_key_persists_once_test() {
  use db <- test_helper.with_db
  let context = ctx(db)
  let first =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-1",
    )
    |> wait.create(context)
  // Retry with the SAME key but a DIFFERENT duration: dedup -> exactly one row.
  let second =
    test_helper.keyed_request(
      "{\"for\":\"1 hour\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "k-1",
    )
    |> wait.create(context)
  assert first.status == 202
  assert second.status == 202
  assert test_helper.eventually_count(db, 1, 2000) == 1
}
```

- [ ] **Step 12: Rewrite the SQL integration tests**

Replace the full contents of `test/notyet/wait/sql_integration_test.gleam`:

```gleam
import gleam/dynamic/decode
import notyet/wait/sql
import pog
import test_helper

const v4_a = "f47ac10b-58cc-4372-a567-0e02b2c3d479"

const v4_b = "c9bf9e57-1685-4c89-bafb-ff5af830be8a"

const ts = "2026-05-20T12:00:00Z"

pub fn insert_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(
      db,
      [v4_a, v4_b],
      [v4_a, v4_b],
      ["k-a", "k-b"],
      ["{\"k\":1}", ""],
      ["5 minutes", "1 hour"],
      [ts, ts],
      [ts, ts],
    )
  assert count == 2
  assert test_helper.count_waits(db) == 2
}

pub fn insert_single_row_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(db, [v4_a], [v4_a], ["k-a"], [""], ["1 day"], [ts], [ts])
  assert count == 1
}

pub fn empty_data_becomes_null_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["k-a"], [""], ["1 day"], [ts], [ts])
  let assert Ok(pog.Returned(_, [is_null])) =
    "SELECT (data IS NULL) FROM waits"
    |> pog.query
    |> pog.returning({
      use b <- decode.field(0, decode.bool)
      decode.success(b)
    })
    |> pog.execute(db)
  assert is_null == True
}

pub fn empty_list_no_op_test() {
  use db <- test_helper.with_db
  let assert Ok(pog.Returned(count, _)) =
    sql.insert_waits(db, [], [], [], [], [], [], [])
  assert count == 0
  assert test_helper.count_waits(db) == 0
}

// DO NOTHING: a repeated key across calls inserts no second row, no error.
pub fn same_key_dedups_to_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["key-1"], [""], ["5 minutes"], [ts], [
      ts,
    ])
  let assert Ok(_) =
    sql.insert_waits(db, [v4_b], [v4_b], ["key-1"], [""], ["1 hour"], [ts], [ts])
  assert test_helper.count_waits(db) == 1
}

// DO NOTHING tolerates an intra-statement duplicate key (unlike DO UPDATE,
// which raises "cannot affect row a second time").
pub fn intra_batch_same_key_one_row_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(
      db,
      [v4_a, v4_b],
      [v4_a, v4_b],
      ["same", "same"],
      ["", ""],
      ["1 day", "1 day"],
      [ts, ts],
      [ts, ts],
    )
  assert test_helper.count_waits(db) == 1
}

pub fn distinct_keys_two_rows_test() {
  use db <- test_helper.with_db
  let assert Ok(_) =
    sql.insert_waits(db, [v4_a], [v4_a], ["key-1"], [""], ["1 day"], [ts], [ts])
  let assert Ok(_) =
    sql.insert_waits(db, [v4_b], [v4_b], ["key-2"], [""], ["1 day"], [ts], [ts])
  assert test_helper.count_waits(db) == 2
}
```

- [ ] **Step 13: Update the router integration test**

Replace the full contents of `test/notyet/router_integration_test.gleam`:

```gleam
import gleam/http
import notyet/router
import test_helper
import wisp/simulate

fn dummy_ctx() {
  // Router-only paths (405/404) never reach the writer, so an unstarted-pool
  // connection is safe.
  test_helper.writer_ctx(test_helper.dummy_connection(), 1, 200, 4)
}

pub fn wrong_method_returns_405_test() {
  let response =
    simulate.request(http.Put, "/wait") |> router.handle_request(dummy_ctx())
  assert response.status == 405
}

pub fn unknown_route_returns_404_test() {
  let response =
    simulate.request(http.Get, "/unknown") |> router.handle_request(dummy_ctx())
  assert response.status == 404
}

pub fn post_wait_happy_path_test() {
  use db <- test_helper.with_db
  let ctx = test_helper.writer_ctx(db, 1, 200, 4)
  let response =
    test_helper.keyed_request(
      "{\"for\":\"5 minutes\",\"activity\":\"" <> test_helper.v4 <> "\"}",
      "router-k1",
    )
    |> router.handle_request(ctx)
  assert response.status == 202
  assert test_helper.json_field(simulate.read_body(response), "status")
    == "accepted"
  assert test_helper.eventually_count(db, 1, 2000) == 1
}
```

- [ ] **Step 14: Update `.env` and `.env.example`**

In **both** `.env` and `.env.example`, remove the `WAIT_BATCH_ACK_TIMEOUT_MS` line and the batch-writer comment block, and set the batch section to:

```bash
# Batch writer (all required). The write path is async: POST /wait returns 202
# on enqueue; the insert happens in a spawned worker. Flush on MAX_SIZE rows or
# INTERVAL_MS after the first pending row. MAX_IN_FLIGHT bounds concurrent insert
# workers; DB_POOL_SIZE must be >= MAX_IN_FLIGHT or inserts serialize on the pool.
# ENQUEUE_TIMEOUT_MS is the in-memory enqueue call timeout (small).
WAIT_BATCH_MAX_SIZE=50
WAIT_BATCH_INTERVAL_MS=50
WAIT_BATCH_MAX_IN_FLIGHT=8
WAIT_DB_POOL_SIZE=10
WAIT_ENQUEUE_TIMEOUT_MS=1000
```

(Keep the Postgres/app lines above unchanged in each file. `.env.example` uses the same values.)

- [ ] **Step 15: Verify the whole suite**

DB must be up + migrated.

```bash
make test
```
Expected: PASS. All async assertions go through `eventually_count`; shed/pipelining/cap tests are deterministic via the gated insert.

If `make sqlgen` produced a different `insert_waits` return type than `pog.Returned(Nil)`, reconcile the `Insert` alias + `do_insert` signature (Step 4) and the gated insert's `Ok(pog.Returned(0, []))` (Step 10) with the generated type, then re-run.

- [ ] **Step 16: Commit**

```bash
git add -A
```
```bash
git commit -m "feat(wait): async 202 write path (coordinator, in-flight cap, 429 shed)"
```

---

## Task 3: Documentation

**Files:** Modify `CLAUDE.md`.

- [ ] **Step 1: Update the architecture + contract sections**

In `CLAUDE.md`, apply these changes:

1. **Environment** section — replace the `WAIT_BATCH_ACK_TIMEOUT_MS` bullet with:

```
- `WAIT_BATCH_MAX_IN_FLIGHT` — max concurrent insert workers the coordinator spawns.
- `WAIT_DB_POOL_SIZE` — pog pool size; **must be `>= WAIT_BATCH_MAX_IN_FLIGHT`** (asserted at boot) or inserts serialize on connection checkout and pipelining is lost.
- `WAIT_ENQUEUE_TIMEOUT_MS` — timeout for the in-memory enqueue call (small; the actor replies immediately, so this only trips if the actor is dead/overloaded → 500).
```

2. **`src/notyet/wait/batch.gleam`** bullet — replace with:

```
- **`src/notyet/wait/batch.gleam`** — write-behind **coordinator** actor. `enqueue(subject, record, timeout)` is a fast in-memory `process.call` returning `Result(Nil, Nil)` (`Ok` → accepted, `Error` → shed). The actor buffers and on `WAIT_BATCH_MAX_SIZE` rows **or** `WAIT_BATCH_INTERVAL_MS` **spawns a short-lived worker** (`spawn_unlinked` + `monitor`) to run the batch upsert, then returns to accept more enqueues (pipelining). At most `WAIT_BATCH_MAX_IN_FLIGHT` workers run at once; when the buffer is full **and** all slots are busy the actor sheds (`Error` → `429`). Worker completion is the monitor `Down` (one per worker on any exit), so a slot never leaks or double-frees. Before inserting it `dedup_by_key`s the buffer. Failures are best-effort: logged (`wisp.log_error`) then dropped. `start_with_insert` is a test seam injecting the insert.
```

3. **`POST /wait` contract** paragraph — replace the response/persistence wording with:

```
`POST /wait` contract: requires an **`Idempotency-Key` header** (non-empty; missing/empty → `422`, checked before the body) and a JSON body `{"for": <duration string>, "activity": <uuid v4>, "data"?: <json object>}` → **`202 {"status": "accepted"}`** (ack-on-enqueue; no row echoed) when accepted into the write buffer, or **`429` + `Retry-After`** when the buffer is full and all in-flight insert slots are busy (load-shed). The wait is persisted **asynchronously** via the batched write-behind path (`status = 'accepted'`); a failed insert is logged and dropped (best-effort, no dead-letter). **Idempotency:** writes are deduplicated by `Idempotency-Key` (`UNIQUE` column + `ON CONFLICT DO NOTHING`); a repeat with the same key never creates a second row. A retry after a `429` is safe. `activity` is **required** and validated as a strict **UUID v4**; missing/non-string/non-UUID/non-v4 → `422`. Invalid/missing/non-duration `for` → `422`. Wrong method on `/wait` → `405`. `data` is optional; when present it must be a JSON object, stored as JSONB (absent → SQL `NULL`); a non-object `data` → `422`. `status` is a state machine seeded at `accepted` (the `waits.status` column defaults to `'accepted'` with `CHECK (status IN ('accepted','waiting'))`). Reading a wait back (e.g. `GET /wait/{key}`) is a future endpoint.
```

4. **Testing conventions** — replace the batch-writer testing bullet with:

```
- The coordinator is tested against a live DB with **eventual** assertions (`test_helper.eventually_count` polls until the expected row count or a deadline) because persistence is async. Shed (`429`), in-flight cap, and pipelining are deterministic via a **gated insert** (`batch.start_with_insert` + an insert that signals start then sleeps to hold a slot). Tests cover both flush triggers, draining held batches, dedup (intra-batch + across calls), shed under saturation, the in-flight cap, and two-worker pipelining.
```

5. Remove the sentence about `WAIT_BATCH_ACK_TIMEOUT_MS` / "Must exceed `WAIT_BATCH_INTERVAL_MS`" from the Environment section (no longer applicable).

- [ ] **Step 2: Verify nothing else references the old contract**

```bash
grep -rn "ack_timeout\|ACK_TIMEOUT\|PersistedWait\|encode_response\|received" CLAUDE.md src test
```
Expected: no matches (anything found must be reconciled before commit; `received` should only ever have been the old status).

- [ ] **Step 3: Final full verification**

```bash
make test
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
```
```bash
git commit -m "docs: async 202 write path contract and config"
```

---

## Self-Review

**Spec coverage:** `202`/`429`/`422`/`405` contract (Task 2 Steps 6, 11, 13) ✓; coordinator + spawn + in-flight cap + shed + monitor-completion (Step 4) ✓; `DO NOTHING` upsert (Steps 1-2) ✓; status `accepted` (Task 1) ✓; config `MAX_IN_FLIGHT`/`DB_POOL_SIZE`/`ENQUEUE_TIMEOUT_MS` + `pool_size >= max_in_flight` assert, drop `ACK_TIMEOUT` (Step 7, 14) ✓; remove `PersistedWait`/`encode_response`/encoder test (Steps 3, 6, 9) ✓; eventual-persistence tests + deterministic shed (Steps 8, 10-13) ✓; docs (Task 3) ✓.

**Deviation from spec (resolves a flagged risk):** the spec proposed the worker send `FlushDone` with the monitor as a backup. That double-counts (a normal worker exit fires the monitor `Down` too). This plan instead makes the monitor `Down` the **single** completion signal (`WorkerDone`); the worker sends nothing. This is the spec's explicitly-deferred "decide during impl" point and removes the double-free and the leak in one stroke.

**Type consistency:** `Config(max_size, interval_ms, max_in_flight)` used identically in `batch.start`, `start_with_insert`, `test_helper.start_writer`, `notyet.main`. `enqueue → Result(Nil, Nil)`; handler matches `Ok`/`Error`. `web.Context(batch, enqueue_timeout_ms)` used in `writer_ctx` + `main`. `Insert` alias return type == `do_insert` == `sql.insert_waits` (reconcile against squirrel output at Step 2/15).

**Open verify-points (called out inline):** squirrel's exact `insert_waits` return type after dropping `RETURNING` (Step 2/15); `process.select_monitors` catch-all routing every worker `Down` to `WorkerDone` (Step 4).
