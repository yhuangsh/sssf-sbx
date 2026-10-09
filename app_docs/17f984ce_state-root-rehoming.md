# STATE-ROOT RE-HOMING — an app run leaves nothing in the kernel

Run `17f984ce` (roster `sssf.meta11.config.yaml`, protected files lifted for
exactly this run) moves every file an app run generates beside the project it
belongs to. Before: mounting/running an app left run records in `.sandbox/runs/`,
the trace db and agent sessions in `adws/adw_data/`, and `specs/`/`app_docs/`
products in the kernel tree. After: an app run (local mode, or target mode with
`app.local_path`, or sandbox-only target mode) accumulates **nothing** in the
kernel. Kernel-self (vendored) runs are unchanged — those artifacts belong to
the kernel project.

## The one rule

Resolved per run from the active roster (`SSSF_CONFIG`):

| mode | state root |
| --- | --- |
| local / target WITH `app.local_path` | `<local_path>/sssf/` |
| target WITHOUT `local_path` (sandbox-only) | `~/.sssf/apps/<app-key>/` |
| vendored (no `app.repo`, no local clone) | `.sandbox/runs/` + `adws/adw_data/` (UNCHANGED) |

`app-key` = sanitized `app.repo` basename (minus `.git`, lowercased, non-alnum →
`-`): `hello-server.git` → `hello-server`. Layout under a root: `runs/<id>.json`,
`runs/<id>-artifacts/`, `runs/<id>.bundle`, `runs/<id>.watcher.log`,
`repos/<app>.git`, `sssf.db`, `sessions/`, `ui.port`.

## What changed

### `sandbox_mount/host/run_record.py` — the resolution API (stdlib only)

- `LEGACY_RUNS_DIR` replaces the old `RUNS_DIR`; `app_key()`,
  `resolve_state_root(roster)` (`None` = vendored), `state_root()`
  (`$SSSF_CONFIG`), `runs_dir()`, `resolve_record_path()`.
- Writes go to `runs_dir()`; **reads search the new location first, then legacy
  `.sandbox/runs/`** (transition compatibility). A record that exists only in
  legacy is read and updated **in place** pre-migration.
- `list_runs()` merges both locations, dedup by `run_id` (new wins).
- New CLI: `state-root` (empty line in vendored mode), `runs-dir`, and
  `migrate`. `migrate` moves every legacy `<id>.json` / `<id>-artifacts/` /
  `<id>.bundle` / `<id>.watcher.log` into the state root; the record uses
  write → read-back-verify → remove, so a failed move never loses a record; it
  is idempotent and exits 1 (sources intact) if anything fails. The harvest
  fields (`base_ref`/`base_sha`/`merge_mode`/`merge_sha`/`harvest_state`) move
  with the record files automatically.

### `adws/adw_modules/state_root.py` (new) — the chain internals

`resolve(app)` / `effective_data_dir(app, configured)` / `effective_db(...)`.
Wired into `session.py` (Tracer db + events.jsonl) and `runner.py` (session
dir), so a LOCAL run's trace db and sessions land under `<local_path>/sssf/`.
In a VM the host `local_path` is not a path on that filesystem, so the in-VM
chain keeps kernel locations — the host-side artifacts re-home via `run_record`,
and teardown's VM-relative `$DB_REL` tar set still finds the db.

### Agents work in the payload

`runner.Run` now sets the agent working root to the resolved payload clone
(`payload_root`) whenever it is separate from the factory — LOCAL **and**
TARGET. Previously agents were spawned in the factory, so in LOCAL mode their
code edits landed in the kernel and the payload commit was empty. Gates
(`gates.py`) now resolve envelope paths against `run.repo_root`, so a bare
`specs/<id>_*.md` is looked up where the agent actually wrote it.

### Payload-aware commit routing — `git_helper.route_kernel_products()`

`route_kernel_products(adw_id, payload, kernel_root)` MOVES this run's
`specs/<adw_id>_*.md` and `app_docs/<adw_id>_*.md` into the payload clone. It is
called before every commit phase in `adw_plan_build.py`,
`adw_plan_build_test.py`, `adw_plan_build_test_quality.py`, and
`adw_simple_sdlc.py` (the last inside its `commit()` helper, covering
commit_plan/commit_build/commit_docs), gated on `cfg.app.local_path`. With
agents now in the payload this is a safety net for any stray factory-side
product; vendored mode is a no-op.

### Consumers re-homed

`just/sandbox/{lifecycle/execute,lifecycle/teardown,manage/harvest,manage/list}.just`
use `run_record.py runs-dir` / `state-root` instead of hardcoding
`.sandbox/runs`; `obs.just` reads `<root>/sssf.db` when the roster asks for the
plain default; `issue_tracker.py` and `compare_runs.py` resolve runs/artifacts/
bundles/cache through `run_record`; `local_ui.py` resolves the db (and `ui.port`)
through the same rule; `ensure_trace_db.py` redirects the plain default.

### Arming

`just local mount` adds `sssf/` to the app clone's `.gitignore` and commits it on
the run branch (idempotent; the appended line is the one allowed dirty change);
`just/sandbox/mount.just` does the same best-effort for `app.local_path`;
`scaffold.py`'s generated `.gitignore` carries `sssf/`. `scaffold.py` no longer
namespaces generated rosters under `adws/adw_data/local/<key>` — they get plain
defaults and rely on resolution.

### Hygiene

`adws/adw_sssf_config/sssf.meta8.config.yaml` was already deleted (commit
`2a8ad90`); verified with `git ls-files` — nothing to remove. The meta11 roster
is NOT deleted here (its own header says "delete when the feature lands"; that
is the commit phase's job).

## Verification (real runs)

- **(a) localized A and B** — `/tmp/verify/A` (hello-server), `/tmp/verify/B`
  (scratch bun app), each with its own scratch roster (`local_path`). `just
  local mount` + `just local execute <id> plan-build "…"`. A's state entirely
  under `<A>/sssf/` (runs/, db, sessions); B's under `<B>/sssf/`; no cross
  population; `sssf/` armed in both clones; the code, `specs/` and `app_docs/`
  products committed on each clone's `local/<run-id>` branch; A's issue closed
  `accepted` with `sssf:local`. Kernel tree clean — the only untracked file is
  the new `state_root.py`.
- **(b) sandbox mode with local_path** — `just sbx mount` (gates A–E pass),
  `just sbx lifecycle execute <id> … plan-build`, `just sbx lifecycle teardown`.
  Record at `<local_path>/sssf/runs/<id>.json`, artifacts at
  `<local_path>/sssf/runs/<id>-artifacts/`, bundle at
  `<local_path>/sssf/runs/<id>.bundle`, cache at `<local_path>/sssf/repos/`;
  harvest merged into the local clone with `harvest_state=merged` + `merge_sha`
  recorded on the re-homed record; the VM was destroyed. Kernel `.sandbox/`
  gained nothing.
- **(c) sandbox-only fallback** — a record with a `app.repo`-only roster lands
  under `~/.sssf/apps/<app-key>/runs/`; legacy `.sandbox/runs/` records still
  resolve via `run_record.py get`/`list`.
- **(d) migration** — a legacy record + artifacts + bundle moved into the state
  root; `get`/`list` resolve from the new location; a forced failure (unwritable
  destination) left the source intact and exited 1.
- **(e) kernel-self regression** — a vendored run traces/sessions kernel-side
  (`adws/adw_data/`), `state-root` is empty, `runs-dir` is legacy, and
  `route_kernel_products` is a no-op.

## Out of scope

The factory repo; the parked ref-guard / rollback-index / deleted_files items;
deleting the meta11 roster.
