# World-class CI pipeline + testcontainers test DB — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the test database self-provisioning via `testcontainers_gleam`, bump runtime OTP 28→29, turn coverage into an 85% gate, and add a four-job GitHub Actions pipeline.

**Architecture:** A single Gleam bootstrap (`test/testdb.gleam`) starts a `postgres:18-alpine` container (reuse + Ryuk disabled), migrates in-process via the `cigogne` library API, sets `DATABASE_URL`, and writes the URL to `build/coverage/.test_db_url`. The test runner (`notyet_test.main`) and the squirrel runner call it directly; the coverage escript (a separate BEAM) reads the URL file to reach the surviving container. CI runs four parallel gates: `lint`, `test` (+Codecov), `sqlcheck`, `docker`.

**Tech Stack:** Gleam 1.16, Erlang/OTP 29, Elixir 1.18 (required by `testcontainers_gleam`), Postgres 18, `cigogne`, `squirrel`, Erlang `cover` + `covertool`, GitHub Actions, `erlef/setup-beam@v1`, `codecov/codecov-action@v5`.

**Spec:** `docs/superpowers/specs/2026-05-22-ci-pipeline-design.md`

---

## Verified facts (do not re-litigate)

- `gleam run -m <module>` runs modules under `test/` and gives them access to dev-dependencies (confirmed empirically; `make sqlgen`/`make sqlcheck` already run dev-dep modules this way).
- `testcontainers_gleam` API (hex v2.0.0):
  - `testcontainers_gleam/postgres`: `new() -> PostgresConfig` (defaults image `postgres:15-alpine`, user/password/database all `"test"`, port 5432), `with_image`, `with_user`, `with_password`, `with_database`, `with_reuse(cfg, Bool)`, `build(cfg) -> Container`, `port(Container) -> Int` (host-mapped port).
  - `testcontainers_gleam`: `start_container(Container) -> Result(Container, ContainerError)` (auto-starts the GenServer internally), `stop_container(id) -> Result(Nil, _)`.
  - `testcontainers_gleam/integration`: `main() -> Nil` is a drop-in replacement for `gleeunit.main()` that sets `TESTCONTAINERS_RYUK_DISABLED=1` and runs with a 600s per-test timeout, then `halt`s with the status code.
  - `testcontainers_gleam/container`: `container_id(Container) -> String`.
- `cigogne` library API: `config.Config(database:, migration_table:, migrations:)`, `config.UrlDbConfig(url)`, `config.default_mig_table_config`, `config.MigrationsConfig(application_name:, migration_folder:, dependencies:, no_hash_check:)`, `cigogne.create_engine(Config) -> Result(MigrationEngine, _)`, `cigogne.apply_migrations(MigrationEngine) -> Result(Nil, _)`. The CLI default config (empty `priv/cigogne.toml`) resolves migrations from the app's `priv/migrations` with application name `notyet`.
- `squirrel.main()` reads `DATABASE_URL` (via `envoy`), parses its own process argv (`check` ⇒ verify, no arg ⇒ generate), and `exit`s with a status. It is a dev-dependency, importable from `test/`.
- `simplifile.write(to:, contents:)` / `simplifile.read(from:)` and `simplifile.create_directory_all` are available (transitive dep).
- The coverage escript (`bin/coverage.escript`) runs `eunit:test` directly in a **separate BEAM** that never calls `notyet_test.main`; it must obtain `DATABASE_URL` itself. Because the preceding `gleam test` run disables Ryuk and does not auto-remove, its container survives into the escript run.
- Ryuk disabled means containers are not auto-reaped; `with_reuse(True)` prevents accumulation across local runs by reusing the same container.

---

## File structure

- Create `test/testdb.gleam` — DB bootstrap: start container, set `DATABASE_URL`, write URL file, migrate. One responsibility: provisioning a migrated test DB.
- Create `test/squirrel_db.gleam` — thin runner: `testdb.setup()` then `squirrel.main()` (argv decides generate vs check).
- Modify `test/notyet_test.gleam` — call `testdb.setup()` then `integration.main()`.
- Modify `bin/coverage.escript` — read the URL file into `DATABASE_URL`; fail under 85% line coverage.
- Modify `gleam.toml` — add `testcontainers_gleam` + `simplifile` dev-deps.
- Create `.tool-versions` — pin erlang/gleam/elixir.
- Modify `Makefile` — `sqlgen`/`sqlcheck` use the new runner.
- Modify `Dockerfile` — runtime OTP 28→29.
- Create `.github/workflows/ci.yml` — four-job pipeline.
- Modify `CLAUDE.md` — document the testcontainers flow, OTP 29, coverage gate.

`test_helper.gleam` is intentionally **unchanged**: `start_pool` keeps reading `DATABASE_URL`, which `testdb.setup()` now populates in-process.

---

## Task 1: Add dependencies and toolchain pins

**Files:**
- Modify: `gleam.toml`
- Create: `.tool-versions`

- [ ] **Step 1: Add dev-dependencies**

Edit `gleam.toml`, in the `[dev_dependencies]` block add:

```toml
testcontainers_gleam = ">= 2.0.0 and < 3.0.0"
simplifile = ">= 2.0.0 and < 3.0.0"
```

- [ ] **Step 2: Download deps**

Run: `gleam deps download`
Expected: resolves and downloads `testcontainers_gleam`, `testcontainers` (Elixir), `simplifile`, and the Elixir runtime. No version-conflict error.

- [ ] **Step 3: Create `.tool-versions`**

Create `.tool-versions` with exactly:

```
erlang 29.0
gleam 1.16.0
elixir 1.18.4-otp-29
```

- [ ] **Step 4: Verify the toolchain compiles**

Run: `gleam build`
Expected: `Compiled in ...` with no errors. (Elixir presence is required at test time, not for `gleam build`; this just confirms deps resolve.)

- [ ] **Step 5: Commit**

```bash
git add gleam.toml manifest.toml .tool-versions
git commit -m "build: add testcontainers_gleam + simplifile dev-deps and tool-versions"
```

---

## Task 2: DB bootstrap module + wire the test runner

**Files:**
- Create: `test/testdb.gleam`
- Modify: `test/notyet_test.gleam`

- [ ] **Step 1: Write `test/testdb.gleam`**

Create `test/testdb.gleam`:

```gleam
//// Test database provisioning via testcontainers.
////
//// `setup` starts a postgres:18-alpine container (reused across runs, Ryuk
//// disabled so it survives into the coverage escript's separate BEAM), sets
//// `DATABASE_URL` in-process, persists the URL to `build/coverage/.test_db_url`
//// for the coverage escript to read, and applies migrations via the cigogne
//// library API.

import cigogne
import cigogne/config
import envoy
import gleam/int
import gleam/option
import simplifile
import testcontainers_gleam
import testcontainers_gleam/postgres

pub const url_file = "build/coverage/.test_db_url"

pub fn setup() -> Nil {
  let container =
    postgres.new()
    |> postgres.with_image("postgres:18-alpine")
    |> postgres.with_reuse(True)
    |> postgres.build

  let assert Ok(running) = testcontainers_gleam.start_container(container)
    as "failed to start postgres testcontainer (is Docker running?)"

  let port = postgres.port(running)
  let url = "postgres://test:test@localhost:" <> int.to_string(port) <> "/test"

  envoy.set("DATABASE_URL", url)
  let _ = simplifile.create_directory_all("build/coverage")
  let _ = simplifile.write(to: url_file, contents: url)

  migrate(url)
}

fn migrate(url: String) -> Nil {
  let cfg =
    config.Config(
      database: config.UrlDbConfig(url),
      migration_table: config.default_mig_table_config,
      migrations: config.MigrationsConfig(
        application_name: "notyet",
        migration_folder: option.None,
        dependencies: [],
        no_hash_check: option.None,
      ),
    )

  let assert Ok(engine) = cigogne.create_engine(cfg)
    as "cigogne create_engine failed"
  let assert Ok(_) = cigogne.apply_migrations(engine)
    as "cigogne apply_migrations failed"
  Nil
}
```

- [ ] **Step 2: Wire `test/notyet_test.gleam`**

Replace the contents of `test/notyet_test.gleam` with:

```gleam
import testcontainers_gleam/integration
import testdb

pub fn main() -> Nil {
  testdb.setup()
  integration.main()
}
```

- [ ] **Step 3: Run the suite (Docker must be running)**

Run: `gleam test`
Expected: PASS. The first run pulls `postgres:18-alpine` and starts a container, migrations apply, all existing DB-backed tests pass against the container. If `TRUNCATE tasks` errors with "relation does not exist", migrations did not apply — see fallback below.

**Fallback if migrations don't resolve:** set `migration_folder: option.Some("priv/migrations")` in the `MigrationsConfig` and re-run. If that still fails, read `priv/migrations` listing and confirm `cigogne.create_engine` is finding the app priv dir under `build/dev/erlang/notyet/priv`.

- [ ] **Step 4: Run twice to confirm reuse (no container pile-up)**

Run: `gleam test`
Run: `docker ps --filter ancestor=postgres:18-alpine --format '{{.ID}}'`
Expected: the second `gleam test` still passes and `docker ps` shows a single reused container, not one per run.

- [ ] **Step 5: Commit**

```bash
git add test/testdb.gleam test/notyet_test.gleam
git commit -m "test(db): provision test Postgres via testcontainers with in-process migrate"
```

---

## Task 3: Self-contained squirrel runner

**Files:**
- Create: `test/squirrel_db.gleam`
- Modify: `Makefile`

- [ ] **Step 1: Write `test/squirrel_db.gleam`**

Create `test/squirrel_db.gleam`:

```gleam
//// Runs squirrel against a testcontainers-provisioned, migrated Postgres.
//// `gleam run -m squirrel_db`            -> generate typed query modules
//// `gleam run -m squirrel_db -- check`   -> verify generated modules are current
//// squirrel.main reads this process's argv, so the trailing args pass through.

import squirrel
import testdb

pub fn main() -> Nil {
  testdb.setup()
  squirrel.main()
}
```

- [ ] **Step 2: Point Makefile targets at the runner**

In `Makefile`, change the `sqlgen` and `sqlcheck` recipes:

```make
sqlgen:
	gleam run -m squirrel_db

sqlcheck:
	gleam run -m squirrel_db -- check
```

- [ ] **Step 3: Verify the check passes against current SQL**

Run: `make sqlcheck`
Expected: squirrel reports the generated modules are up to date and exits 0 (container starts, migrates, check runs).

- [ ] **Step 4: Verify generation is idempotent**

Run: `make sqlgen`
Run: `git status --porcelain src/notyet/task/sql.gleam`
Expected: no diff (regeneration against the migrated container produces the identical file).

- [ ] **Step 5: Commit**

```bash
git add test/squirrel_db.gleam Makefile
git commit -m "test(db): run squirrel generate/check against a testcontainers DB"
```

---

## Task 4: Coverage reads the URL file + 85% gate

**Files:**
- Modify: `bin/coverage.escript`

- [ ] **Step 1: Read the URL file into `DATABASE_URL`**

In `bin/coverage.escript`, immediately after the `application:ensure_all_started(pgo)` line (around line 38), insert:

```erlang
    %% The preceding `gleam test` run (Ryuk disabled) left its postgres
    %% container alive and wrote its URL here. This separate BEAM never calls
    %% notyet_test:main, so pick up the same DB explicitly.
    case file:read_file("build/coverage/.test_db_url") of
        {ok, UrlBin} ->
            os:putenv("DATABASE_URL", string:trim(binary_to_list(UrlBin)));
        _ ->
            io:format("cover: no .test_db_url file; using ambient DATABASE_URL~n")
    end,
```

- [ ] **Step 2: Make `print_summary` return the totals**

In `bin/coverage.escript`, change the last line of `print_summary/1` from:

```erlang
    print_row("TOTAL", LC, LN, CC, CN).
```

to:

```erlang
    print_row("TOTAL", LC, LN, CC, CN),
    {LC, LN}.
```

- [ ] **Step 3: Enforce the threshold in `main`**

In `bin/coverage.escript` `main/1`, replace:

```erlang
    SrcMods = [beam_module(B) || B <- SrcBeams],
    print_summary(SrcMods),
    write_reports(),
    ok.
```

with:

```erlang
    SrcMods = [beam_module(B) || B <- SrcBeams],
    {TotalLc, TotalLn} = print_summary(SrcMods),
    write_reports(),
    Pct = pct(TotalLc, TotalLn),
    case Pct < 85.0 of
        true ->
            halt_with(lists:flatten(
                io_lib:format("line coverage ~.2f% is below the 85% gate", [Pct])), 1);
        false ->
            io:format("~nLine coverage ~.2f% meets the 85% gate~n", [Pct]),
            ok
    end.
```

- [ ] **Step 4: Run coverage end-to-end**

Run: `./bin/coverage`
Expected: the suite runs under cover, the per-module + TOTAL table prints, then `Line coverage NN.NN% meets the 85% gate` and exit 0 (current line coverage is ~88%). `build/coverage/cobertura.xml` is written.

- [ ] **Step 5: Confirm the gate actually fails low (temporary check)**

Temporarily change `85.0` to `99.0`, run `./bin/coverage`, and confirm it prints `... below the 99% gate` and exits non-zero (`echo $?` ⇒ 1). Then revert to `85.0`.

- [ ] **Step 6: Commit**

```bash
git add bin/coverage.escript
git commit -m "test(coverage): read testcontainers DB URL and gate at 85% line coverage"
```

---

## Task 5: Bump runtime OTP 28 → 29

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Bump the runtime base image**

In `Dockerfile`, change:

```dockerfile
FROM erlang:28-alpine AS runtime
```

to:

```dockerfile
FROM erlang:29-alpine AS runtime
```

- [ ] **Step 2: Validate the multi-stage build compiles**

Run: `docker build --target runtime -t notyet:ci-check .`
Expected: build succeeds through both stages. If `erlang:29-alpine` does not exist on Docker Hub, revert this single line to `erlang:28-alpine`, leave a `# TODO: bump to erlang:29-alpine when published` comment, and note the divergence in the commit message.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "build: bump runtime image to erlang:29-alpine"
```

---

## Task 6: GitHub Actions pipeline

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.run_id }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v6
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "29"
          gleam-version: "1.16.0"
      - run: gleam deps download
      - run: gleam format --check src test
      - run: gleam build --warnings-as-errors

  test:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v6
      - run: sudo apt-get update
      - run: sudo apt-get install -y inotify-tools
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "29"
          gleam-version: "1.16.0"
          elixir-version: "1.18"
      - run: gleam deps download
      - run: ./bin/coverage
      - uses: codecov/codecov-action@v5
        with:
          files: build/coverage/cobertura.xml
          fail_ci_if_error: true
        env:
          CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}

  sqlcheck:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v6
      - run: sudo apt-get update
      - run: sudo apt-get install -y inotify-tools
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "29"
          gleam-version: "1.16.0"
          elixir-version: "1.18"
      - run: gleam deps download
      - run: gleam run -m squirrel_db -- check

  docker:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v6
      - uses: docker/setup-buildx-action@v3
      - run: docker build --target runtime -t notyet:ci .
```

- [ ] **Step 2: Validate YAML locally**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"`
Expected: `yaml ok` (syntactic validation only). If `python3`/`yaml` is unavailable, skip and rely on the first push.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add lint/test/sqlcheck/docker pipeline on GitHub Actions"
```

---

## Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the testing conventions section**

In `CLAUDE.md`, in the "Testing conventions" section, replace the sentence describing DB-backed tests requiring `make db-up && make migrate` with:

> **DB-backed tests are self-provisioning.** `test/testdb.gleam` `setup` (called from `notyet_test.main` and `test/squirrel_db.gleam`) starts a `postgres:18-alpine` container via `testcontainers_gleam` (reuse on, Ryuk disabled), applies migrations in-process through the `cigogne` library API, and sets `DATABASE_URL`. `make test`, `make coverage`, and `make sqlcheck` need only a running Docker daemon — no `make db-up`/`make migrate` first. The coverage escript runs in a separate BEAM and reads the container URL from `build/coverage/.test_db_url`, which the `gleam test` run leaves behind (Ryuk disabled keeps the container alive).

- [ ] **Step 2: Update the Commands section**

In `CLAUDE.md`, update the `make sqlgen`/`make sqlcheck` bullets to note they now provision their own DB via `test/squirrel_db.gleam` (no live external DB needed), and update `./bin/coverage` to note it enforces an 85% line-coverage gate.

- [ ] **Step 3: Note the toolchain + OTP bump**

In `CLAUDE.md` Environment/Architecture, note: tests require **Elixir** (transitive via `testcontainers_gleam`) and a Docker daemon; runtime image is `erlang:29-alpine`; versions are pinned in `.tool-versions`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document testcontainers test DB, coverage gate, and OTP 29"
```

---

## Manual follow-up (not automatable here)

These are out of scope for code changes and must be done by a human after the first push:

1. Create the GitHub remote and push `main`.
2. Decide repo visibility. Public ⇒ Codecov uploads tokenless (the `CODECOV_TOKEN` env line is harmless when empty). Private ⇒ add the `CODECOV_TOKEN` secret in repo settings.
3. Enable branch protection on `main` requiring the four checks: `lint`, `test`, `sqlcheck`, `docker`.

---

## Self-review

- **Spec coverage:** testcontainers suite (Task 2), self-contained sqlcheck (Task 3), in-process cigogne migrate (Task 2), `make db` removed from the test flow / tests self-provision (Tasks 2–3, 7), OTP 28→29 (Task 5), coverage 85% gate (Task 4), Codecov upload (Task 6), four parallel jobs with `permissions`/`concurrency`/`timeout`/pinned versions (Task 6), Elixir + inotify-tools (Tasks 1, 6), docker build validation (Tasks 5–6). All spec items map to a task.
- **Placeholder scan:** no TBD/TODO except the explicit, conditional `erlang:29-alpine` fallback in Task 5 (a real branch with concrete instructions), and the documented migration-folder fallback in Task 2.
- **Type/name consistency:** `testdb.setup/0`, `testdb.url_file`, module `testdb`, module `squirrel_db`, `build/coverage/.test_db_url`, the 85.0 threshold, and the four job names (`lint`/`test`/`sqlcheck`/`docker`) are used identically across tasks.
- **Note on coverage double-run:** `./bin/coverage` runs `gleam test` (container starts, survives) then the escript re-runs under cover against the same container — this matches the existing two-phase coverage design; only the DB source changed.
