# World-class CI pipeline + testcontainers-based test DB

Date: 2026-05-22

## Goal

Stand up a world-class CI pipeline for `notyet` on GitHub Actions, and convert
the test database provisioning from an externally-managed Postgres
(docker-compose + `make db-up`) to **self-contained, testcontainers-managed
ephemeral containers**. Every command that needs a database boots its own
Postgres container internally; there is no manual DB lifecycle step.

The work splits into two coupled, sequential blocks:

- **Block A — test infrastructure** (prerequisite): adopt `testcontainers_gleam`,
  make the test suite and the squirrel check self-provisioning, bump the
  runtime OTP, and turn coverage into a hard gate.
- **Block B — CI workflow** (depends on A): four parallel GitHub Actions jobs,
  each a focused gate.

## Research basis (authoritative sources only)

- **`gleam new` CI template** (`gleam-lang/gleam`, `compiler-cli/src/new.rs`):
  baseline is `actions/checkout@v6` → `erlef/setup-beam@v1`
  (otp+gleam+rebar3) → `gleam deps download` → `gleam test` →
  `gleam format --check src test`.
- **`gleam-lang/stdlib` CI** (`.github/workflows/ci.yml`): the production-grade
  shape — `permissions: contents: read`, a `concurrency` group with
  `cancel-in-progress: true`, per-job `timeout-minutes`, an OTP matrix with
  `fail-fast: false`, and a pinned `gleam-version`.
- **`testcontainers_gleam`** (hex v2.0.0, `gleam >= 1.7`, dev-dependency):
  builder API (`container.new("postgres:18-alpine") |> with_exposed_port |>
  with_environment |> with_waiting_strategy |> with_auto_remove`), start →
  `mapped_port` → dynamic `DATABASE_URL`. Wraps the **Elixir** `testcontainers`
  library, so **Elixir + a running Docker daemon are required**. On Linux/CI it
  needs `inotify-tools`; Ryuk is auto-disabled by the runner. Integration tests
  are gated behind `integration.guard()` + env `TESTCONTAINERS_INTEGRATION_TESTS=1`.
- **`cigogne`** exposes a library API (`create_engine(config)`,
  `apply_migrations(engine)`) — migrations can run in-process, no shelling out.
- **`squirrel`** only exposes `main()` (reads `DATABASE_URL` via `envoy`, parses
  argv for `check`/generate, calls `exit` with a status). It is a dev-dependency,
  so a `test/` module can import it and call `squirrel.main()` in-process.

## Versions

- **Gleam 1.16.0** is already the latest release — no bump needed.
- **OTP**: the Dockerfile runtime is `erlang:28-alpine`; **OTP-29.0 is GA**, so we
  are one major behind. Bump runtime to `erlang:29-alpine` and pin CI to OTP 29.
- The OTP of the `gleam:v1.16.0-erlang-alpine` build-stage image and the
  existence of an `erlang:29-alpine` tag could not be verified offline. The
  **`docker` CI job is the proof**: if the bumped Dockerfile builds, it is valid.
  If an erlang-29 gleam build image does not exist yet, keep the current build
  image and document the build/runtime OTP divergence.

---

## Block A — test infrastructure

### A1. Dependencies & toolchain

- `gleam.toml` dev-dependencies: add
  `testcontainers_gleam = ">= 2.0.0 and < 3.0.0"`.
- This transitively requires **Elixir** (the lib wraps Elixir `testcontainers`)
  and a running **Docker daemon**.
- Add `.tool-versions` pinning `erlang 29.x`, `gleam 1.16.0`, and
  `elixir 1.18.x` (latest stable; adjust only if `setup-beam`/the lib reports an
  incompatibility) — consumed by `erlef/setup-beam` in CI and by asdf/mise
  locally.
- Linux/CI requires the `inotify-tools` system package.

### A2. Self-contained test suite (`make test`)

- `test/test_helper.gleam` `start_pool` (or a setup seam it calls):
  1. Build a `postgres:18-alpine` container via the testcontainers builder:
     dynamic exposed port, `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`
     env, `with_waiting_strategy(log("ready to accept connections", ...))`,
     `with_auto_remove(True)`.
  2. Start it, read the `mapped_port`, compose the `DATABASE_URL`.
  3. Run migrations in-process: `cigogne.create_engine(config_with_url)` then
     `apply_migrations(engine)`.
  4. Hand the `pog` pool (sized from the dynamic URL) to the tests.
- `with_db` (TRUNCATE `tasks` then run) is unchanged.
- Container teardown happens at suite end (auto-remove + explicit stop).
- **No `make db` step.** `make test` is fully self-contained — the
  "forgot to start the DB" footgun is gone.
- Integration tests that hit the DB are gated with `integration.guard()` and
  only run when `TESTCONTAINERS_INTEGRATION_TESTS=1`.

### A3. Self-contained squirrel check (`make sqlcheck`)

- New entrypoint `test/sqlcheck_runner.gleam` (imports the dev-deps
  `testcontainers_gleam`, `cigogne`, `squirrel`), `main`:
  1. Start an ephemeral `postgres:18-alpine` container (dynamic port).
  2. `envoy.set("DATABASE_URL", url)`.
  3. Migrate in-process (`cigogne.create_engine` + `apply_migrations`).
  4. Call `squirrel.main()` — it reads `check` from argv and `exit`s with a
     status that becomes the gate result.
- `make sqlcheck` becomes a single line:
  `gleam run -m sqlcheck_runner -- check`.
- Note: `squirrel.main()` calls `exit`, terminating the BEAM before any Gleam
  teardown runs; the container is still reaped by the Docker daemon
  (auto-remove). Acceptable.

### A4. Makefile after the change

- **Removed from the test flow**: `db-up`, `db-down`, `db-logs` (compose
  Postgres is no longer a test prerequisite).
- `migrate` / `migrate-new` / `migrate-rollback` / `migrate-status`: kept for
  local dev (run against an ad-hoc DB or an explicitly set `DATABASE_URL`).
- `test`, `sqlcheck`, `coverage`: self-contained — they boot their own
  container. These targets export `TESTCONTAINERS_INTEGRATION_TESTS=1` so the
  `integration.guard()`-gated tests actually run.
- One command per line everywhere (existing repo rule).

### A5. docker-compose

- `docker-compose.yml` Postgres stays **only** for the runtime stack
  (`postgres` → `migrate` → `app`). It is no longer used by tests.

### A6. OTP bump + coverage gate

- Dockerfile: runtime `erlang:28-alpine` → `erlang:29-alpine`. Bump the
  build-stage gleam image to an erlang-29 variant if one exists; otherwise keep
  it and record the divergence. The `docker` CI job validates the result.
- `bin/coverage`: exit non-zero when **line coverage < 85%** (today it only
  prints). Threshold lives in the script as a single tunable value.

---

## Block B — CI workflow

Single file `.github/workflows/ci.yml`. Four parallel jobs, each a focused gate.

### Shared configuration

```yaml
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
```

Every job: `runs-on: ubuntu-latest`, `timeout-minutes` set,
`actions/checkout@v6`, and `erlef/setup-beam@v1` pinned to
`otp-version: "29"`, `gleam-version: "1.16.0"`, `elixir-version: "1.18"`.

### Job 1 — `lint` (no DB, no Docker)

- setup-beam → `gleam deps download`
- `gleam format --check src test`
- `gleam build --warnings-as-errors`

### Job 2 — `test` (Docker + Elixir + inotify-tools)

- `apt-get install -y inotify-tools`
- setup-beam → `gleam deps download`
- `TESTCONTAINERS_INTEGRATION_TESTS=1 ./bin/coverage` (boots its own Postgres,
  runs the suite, fails if line coverage < 85%)
- `codecov/codecov-action@v5` uploading `build/coverage/cobertura.xml`

### Job 3 — `sqlcheck` (Docker + Elixir + inotify-tools)

- `apt-get install -y inotify-tools`
- setup-beam → `gleam deps download`
- `TESTCONTAINERS_INTEGRATION_TESTS=1 gleam run -m sqlcheck_runner -- check`
  (boots its own Postgres, migrates, runs the squirrel check)

### Job 4 — `docker` (Docker daemon only)

- `docker/setup-buildx-action`
- `docker build --target runtime .` — validates the OTP-29 Dockerfile compiles.
  No push.

### Operational notes

- **Codecov token**: a public repo uploads tokenless (OIDC); a private repo needs
  a `CODECOV_TOKEN` secret. The repo has no remote yet, so visibility — and thus
  whether the secret is required — is decided when the remote is created.
- **Docker-in-Docker**: `ubuntu-latest` ships a running Docker daemon;
  testcontainers talks to it directly. Ryuk is auto-disabled by the lib's runner.
- **Branch protection**: mark the four jobs (`lint`, `test`, `sqlcheck`,
  `docker`) as required status checks. This is configured in GitHub repo
  settings, outside the YAML — a manual step after the first run.

---

## Failure modes & gates summary

| Gate | Job | Fails when |
| --- | --- | --- |
| Formatting | `lint` | `gleam format --check` finds unformatted files |
| Compiler warnings | `lint` | `gleam build --warnings-as-errors` emits any warning |
| Tests | `test` | any gleeunit test fails |
| Coverage | `test` | line coverage < 85% |
| SQL codegen drift | `sqlcheck` | generated `sql.gleam` differs from `*.sql` |
| Dockerfile | `docker` | the OTP-29 multi-stage build fails to compile |

## Out of scope (YAGNI)

- Image publishing / registry push (chosen: build-only validation).
- Release pipeline / version tagging.
- OTP version matrix (app is deployed at a single pinned version).
- Reusable workflows / composite actions (single app, no reuse need).

## Implementation order

1. Block A first (test infra must work locally before CI can rely on it):
   deps + toolchain → suite self-provisioning → sqlcheck runner → Makefile
   cleanup → Dockerfile OTP bump → coverage threshold.
2. Block B second: the four-job workflow.
3. Manual follow-up: create the GitHub remote, decide repo visibility / Codecov
   token, enable branch protection on the four checks.
