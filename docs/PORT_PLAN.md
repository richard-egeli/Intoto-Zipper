# Synology Zipper — Phoenix LiveView Port Plan

**Source:** `../synology_zipper/` (Go). Same feature set; no behavior changes.
**Target:** this repo (Elixir 1.19 + Phoenix 1.7.21 + LiveView + SQLite).

## Go → Elixir mapping

| Go package | Elixir counterpart | Notes |
|---|---|---|
| `internal/state` (SQLite, migrations, queries) | `SynologyZipper.State` context + Ecto schemas + `priv/repo/migrations/` | Source / Month / Run schemas |
| `internal/config` (Source struct + validator) | Embedded in `State.Source` schema + changeset | No YAML loader — DB is the source of truth |
| `internal/planner` | `SynologyZipper.Planner` | Pure module: compute eligible months given grace + start |
| `internal/zipper` | `SynologyZipper.Zipper` | Erlang `:zip` for Store-only; atomic rename |
| `internal/postzip` | `SynologyZipper.PostZip` | Move-only (delete permanently removed, matches Go) |
| `internal/uploader` | `SynologyZipper.Uploader` + `SynologyZipper.Uploader.Drive` | Google Drive v3 via `google_api_drive`. Adopt-orphan-on-list + md5 verify |
| `internal/runner` | `SynologyZipper.Runner` | Orchestrates one tick: plan → zip → postzip → upload |
| `internal/scheduler` | `SynologyZipper.Scheduler` (GenServer) | Periodic tick via `Process.send_after/3` |
| `internal/retry` | `SynologyZipper.Retry` | Straight port; `:retry` hex crate too heavy for 30 lines |
| `internal/web` (net/http + templates) | `SynologyZipperWeb` (LiveView) | `OverviewLive`, `SourceLive`, `RunsLive`; no polling shim |

## Supervision tree

```
SynologyZipper.Application
├── SynologyZipper.Repo                           # Ecto/SQLite
├── Phoenix.PubSub (name: SynologyZipper.PubSub)  # scheduler → LiveView
├── SynologyZipperWeb.Endpoint                    # HTTP + LiveView
├── SynologyZipper.Uploader                       # holds Drive client + disabled-reason
└── SynologyZipper.Scheduler                      # ticks every configured interval
```

## LiveView wins over the Go version

- **No htmx shim.** Status pill, upload column, and row highlights update via `Phoenix.PubSub` broadcasts from the Scheduler; LiveView re-renders.
- **Run-now** = `handle_event("run_now", ...)` that sends a message to the Scheduler; no form post.
- **Crash safety** — a failed upload doesn't bring down the scheduler (Supervisor restart policy) and a crashed LiveView just reconnects without losing state.
- **LiveDashboard** free at `/dev/dashboard` for observability.

## Port sequencing

Each task ends with a commit that compiles + tests pass. Branch = main; no worktrees (fresh repo).

### Task 1 — Schemas + migration

Ecto migration: `sources`, `months`, `runs`. Columns match the Go DB 1:1 (including `drive_folder_id`, `drive_file_id`, `uploaded_at`, `upload_error`, `upload_attempts`; **no** `delete` action). Add unique constraint on `(source_name, month)`.

Schemas: `SynologyZipper.State.Source`, `.Month`, `.Run` — with changesets that enforce: `post_zip ∈ {keep, move}`, `post_zip=move` ⇒ `move_to` required, `auto_upload=true` ⇒ `drive_folder_id` required.

Tests: changeset validation; migration round-trip.

### Task 2 — State context

`SynologyZipper.State`:
- CRUD for sources (create/update/rename/delete, preserving month history on rename)
- `zipped_months(source_name)`, `list_months(source_name)`, `list_sources()`, `list_runs(limit)`
- `start_run / finish_run / start_month_attempt / mark_zipped / mark_zipped_empty / mark_failed / reset_month`
- Upload: `months_pending_upload/0`, `mark_uploaded/4`, `mark_upload_failed/3`

Broadcasts `Phoenix.PubSub` events (`{:source_changed, name}`, `{:month_changed, source, month}`, `{:run_changed, id}`) so LiveViews refresh without polling.

Tests: every mutation round-trips; broadcasts captured via `Phoenix.PubSub.subscribe`.

### Task 3 — Planner + Zipper + PostZip

Pure modules. Ports directly from Go:
- `Planner.eligible_months(source, now, grace_days)` → list of `YYYY-MM` strings.
- `Zipper.write_zip(source_path, month)` → `{:ok, %{path, bytes, file_count, skipped}}` or `{:error, _}`. Atomic rename via `File.rename/2`. Uses Erlang's `:zip` module with `{:uncompressed}` method (matches Go's "store" policy for already-compressed video).
- `PostZip.execute(action, %{source_path, month, source_name, move_to})` — `:keep` returns `:ok`, `:move` uses `File.rename/2`, anything else (legacy `:delete`) is also `:ok` (never destructive on source).

Tests: mirror the Go test matrix, including `TestExecuteNeverRemovesSourceFilesExceptMove` equivalent.

### Task 4 — Retry + Uploader

`SynologyZipper.Retry.retry/3` — options (`attempts`, `base`), transient predicate. Straight port.

`SynologyZipper.Uploader` (GenServer) — holds a `%Drive.Client{}` or `:disabled` state:
- `child_spec/1` reads `GOOGLE_APPLICATION_CREDENTIALS` at start, logs "drive uploader ready" / "drive uploader disabled".
- `upload(pid, %UploadJob{})` → `{:ok, %UploadResult{}} | {:error, reason}`.
- Before `files.create`, lists the folder by `name='YYYY-MM.zip'`; if exactly one match with matching md5 → adopt; mismatch → `{:error, :orphan_md5_mismatch}`; multiple → `{:error, :ambiguous_orphan}`.
- Shared-Drive safe (`supportsAllDrives: true, includeItemsFromAllDrives: true`).

Dependencies added:
- `{:google_api_drive, "~> 0.33"}`
- `{:goth, "~> 1.4"}` — service-account token fetcher
- `{:req, "~> 0.5"}` if we need a finch-backed HTTP client for non-SDK calls

Tests: use `Tesla.Mock` (google_api_drive is Tesla-based) to stub list/create/delete. Same matrix as the Go `uploader_test.go`: success, md5 mismatch, 404, 503, disabled, missing local zip, adopt match, adopt mismatch, ambiguous.

### Task 5 — Runner + Scheduler

`Runner.run(now)` orchestrates plan → zip → postzip → upload for every configured source. Returns a `%Result{}`. On process death mid-run, the in-progress Month row's `upload_attempts` is already incremented (transactions are per-operation), so the next tick retries cleanly.

`Scheduler` is a GenServer:
- `init/1` schedules the first tick (configurable delay, default immediate).
- `handle_info(:tick, state)` calls `Runner.run/1` inside a supervised `Task`, schedules the next tick.
- `run_now/0` is a public API that sends `:tick` immediately (coalesced if one is in flight).
- Broadcasts `{:run_start, run_id}` / `{:run_end, run_id, status}` on PubSub.

Tests: test mode uses a mock uploader injected via config; assert tick ordering + PubSub events.

### Task 6 — LiveView UI

Three LiveViews with live-refresh via PubSub subscriptions:

- `OverviewLive` at `/` — source table with the same columns as the Go dashboard (name, path, start month, grace, post-zip, auto-upload X/Y, last zipped, last status). Rows are clickable.
- `SourceLive` at `/sources/:name` — configuration form + month grid (with upload column) + danger zone. `handle_event("save", _, socket)` runs the changeset; `handle_event("reset_month", _, socket)` calls `State.reset_month/2`.
- `RunsLive` at `/runs` — recent 50 runs.

Status pill in the root layout subscribes to `{:run_start, :run_end}` events — no polling.

Credentials banner: top-of-`app.html.heex`, rendered from a `@banner_warning` assign the root layout computes once per mount, using `Uploader.disabled?/0` + `State.any_auto_upload?/0`.

Styling: Tailwind (ships with Phoenix 1.7). Mirror the existing Go CSS tokens (accent blue, surface, border-strong, badge variants) via Tailwind classes; no need for a separate CSS file.

Tests: Phoenix.LiveViewTest for render + event handling.

### Task 7 — Application wiring + smoke test

Register Scheduler and Uploader in the supervision tree (reading `MIX_ENV=prod` config for tick interval + credentials path). Verify end-to-end: start with a test SQLite file + fake sources, trigger `run_now`, see uploaded rows in DB.

### Task 8 — Docker release + docker-compose

Multi-stage Dockerfile:
- Stage 1: `hexpm/elixir:1.19-otp-28-alpine`, `MIX_ENV=prod mix release`.
- Stage 2: `alpine:3.19` with `libstdc++` (sqlite3 NIF) + the release.

docker-compose.yml mirrors the Go version: mount source dirs, state dir, SA JSON; set `GOOGLE_APPLICATION_CREDENTIALS` + `DATABASE_PATH`.

## Out of scope — keep the Go version's guarantees

Everything that was out-of-scope in `../synology_zipper/docs/superpowers/specs/2026-04-20-auto-upload-design.md` stays out-of-scope here. **Never delete from source.** Never enumerate Drive beyond the configured folder. Serial uploads. One SA for the whole process.

## Verification pass

```
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

Plus manual: `mix phx.server` → http://localhost:4000, create a source, trigger a run, inspect Drive.
