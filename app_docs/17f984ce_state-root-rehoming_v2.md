# STATE-ROOT RE-HOMING — documented

Run `17f984ce` under `adws/adw_sssf_config/sssf.meta11.config.yaml`
(`protected_files: []` lifted for exactly this run; the chain's commit phases
own the landing, no self-commit, no push). Every file an app run generates now
lives beside the project it belongs to; the kernel repo accumulates nothing
from those runs. Kernel-self (vendored) runs are deliberately unchanged.

## The one rule (resolved per run from `$SSSF_CONFIG`)

| mode | state root |
| --- | --- |
| local / target WITH `app.local_path` | `<local_path>/sssf/` |
| target WITHOUT `local_path` (sandbox-only) | `~/.sssf/apps/<app-key>/` |
| vendored (no `app.repo`, no local clone) | `.sandbox/runs/` + `adws/adw_data/` — UNCHANGED |

Layout under a root: `runs/<id>.json`, `runs/<id>-artifacts/`, `runs/<id>.bundle`,
`runs/<id>.watcher.log`, `repos/<app>.git`, `sssf.db`, `sessions/`, `ui.port`.
`app-key` is the sanitized basename of `app.repo` (`hello-server.git` →
`hello-server`).

## What changed and where

### Resolution API + migration — `sandbox_mount/host/run_record.py` (stdlib only)

`RUNS_DIR` is renamed `LEGACY_RUNS_DIR`; the home root is
`HOME_STATE_ROOT = Path.home() / ".sssf" / "apps"`. New helpers:
`app_key(repo_url)`, `_roster_app(path)` (line-based `app:` scan, ignores
`#` comments and blank lines — commented-out `local_path:` does not count),
`resolve_state_root(roster)`, `state_root()` (from `$SSSF_CONFIG`),
`runs_dir()`, `resolve_record_path(run_id)` (new location first, else legacy,
else the new path so the FileNotFoundError names the canonical location).

Semantics change inside `create` / `path` / `get` / `set` / `close` / `_write`:
`create` and `path` write to / name the effective runs dir; `get`/`set`/`close`/
`_write` resolve via `resolve_record_path` so a legacy-only record is read and
updated IN PLACE (pre-migration compatibility). `list_runs()` merges both
locations, dedupes by `run_id` (new wins), same newest-first sort.

New CLI: `state-root` (empty line in vendored/unresolved mode), `runs-dir`,
`migrate`. The migrate path uses `_safe_move(src, dst)` (a `.migrating` staging
file + atomic rename, partial destination cleaned up on failure) for
artifacts/bundles/watcher logs and `_move_record(src, dst)` (write → read-back
verify → remove) for the JSON itself, so a failed move never loses a record.
Idempotent (destination wins), refuses vendored mode, exits 1 with all sources
left intact when anything fails. The harvest fields
(`base_ref`/`base_sha`/`merge_mode`/`merge_sha`/`harvest_state`) move with the
record automatically — they are already in the closed schema.

### Chain internals — `adws/adw_modules/state_root.py` (new)

`resolve(app)`, `effective_data_dir(app, configured)`,
`effective_db(app, configured)`. The same rule, but from the parsed config
object so the live `Tracer` and `Run` can resolve it. Wired into
`session.ensure()` (Tracer db + `events.jsonl`) and `runner.Run.__init__`
(`session_dir`) — a LOCAL run's trace db and sessions land under
`<local_path>/sssf/`.

In a VM the host's `local_path` is not a path on that filesystem, so the in-VM
chain keeps kernel locations — the host-side artifacts re-home via
`run_record`, and teardown's VM-relative `$DB_REL` tar set still finds the db.
Rule (b) (`~/.sssf/apps/<app-key>/`) is host-side state and lives in
`run_record.resolve_state_root`; `state_root` deliberately does not apply it
inside a VM.

### Agents work in the payload — `adws/adw_modules/runner.py`

`Run.factory_root` is the factory clone; `Run.repo_root` now resolves to
`payload_root(cfg.app, factory_root)` — the agent working directory is the
payload clone whenever it differs from the factory (LOCAL **and** TARGET).
Vendored mode (payload == factory) is unchanged. Previously LOCAL-mode agents
were spawned in the kernel, so their code edits landed there and the payload
commit was empty.

`adws/adw_modules/git_helper.py` gains `route_kernel_products(adw_id, payload,
kernel_root)`: a no-op in vendored mode; in LOCAL mode it MOVES this run's
`specs/<adw_id>_*.md` and `app_docs/<adw_id>_*.md` from `kernel_root` into
`payload` (parents created, atomic `shutil.move`). `KERNEL_PRODUCT_DIRS =
("specs", "app_docs")`. With agents now in the payload, this is a safety net
for any stray factory-side product.

Wired into every commit phase: `adw_plan_build.py`,
`adw_plan_build_test.py`, `adw_plan_build_test_quality.py`, and the
`commit()` helper inside `adw_simple_sdlc.py` (covering
`commit_plan`/`commit_build`/`commit_docs`). Each call is gated on
`cfg.app.local_path`.

### Gates now resolve against the agent's working root — `adws/adw_modules/gates.py`

New private helper `_resolve(run, raw)` resolves a relative envelope path
against `run.repo_root` rather than this process's cwd. The four gate
functions (`artifacts_exist`, `files_non_empty`, `json_parses`,
`diff_matches_claims`) now use it, so a bare `specs/<id>_*.md` is looked up
where the agent actually wrote it. In vendored / target modes `repo_root == cwd`
so behavior is identical.

### Minor touched callers

`adws/adw_modules/changes.py` (capture) and `adws/adw_modules/quality.py`
(`_app_dir`) now pass `run.factory_root` to `payload_root` (not `run.repo_root`)
so they keep resolving the payload correctly when agents are spawned in the
payload. `adws/adw_modules/permissions.always_writable` keeps the configured
`data_dir` (the re-homed data dir lives outside the repo; a git snapshot never
sees it, so no grant is needed).

### Host-side consumers

`sandbox_mount/host/local_ui.py` — imports `run_record` and routes
`resolve_db()` through `run_record.resolve_state_root`, so the UI serves the
re-homed `<root>/sssf.db` for an app run and `ui.port` rides along (it lives
beside the db, `db.parent/"ui.port"`).

`sandbox_mount/host/ensure_trace_db.py` — keeps its argv contract; when the
caller names the plain default `adws/adw_data/sssf.db` AND
`run_record.state_root()` resolves, the file lands at `<root>/sssf.db`
(silent fallback if `run_record` import fails).

`sandbox_mount/host/issue_tracker.py` — `_runs_dir()` (`run_record.runs_dir()`)
and `_state_root_or_legacy_sandbox()` replace hardcoded `RUNS_DIR`; bundle
status and surviving-state lines name the path via `_display()` (relative to
`REPO_ROOT` when inside, else absolute). Local-mode commit-branch name is
`local/<run_id>` everywhere; sync-issues' fallback artifact db is the state
root's runs/ dir.

`sandbox_mount/host/compare_runs.py` — same `_runs_dir()` + `_cache_root()`
helpers; added `local/<run_id>` to the ref fallback order (legacy `sbx/<run_id>`
is still tried).

### Recipes

`just/local.just` mount — arms the clone BEFORE the check: appends
`sssf/` to `<LOCAL_PATH>/.gitignore` if missing, treats the appended
`.gitignore` line as the ONE allowed dirty change (other dirty paths still
fail), commits the arming on the run branch. Idempotent.

`just/sandbox/mount.just` — best-effort host-side arming for `app.local_path`
when set; non-fatal, `harvest` re-checks clone cleanliness before merging.

`just/sandbox/manage/harvest.just` — `RUNS="$(run_record.py runs-dir)"`,
bundle and cache paths go there; `ROOT="$(run_record.py state-root)"`
(falls back to `.sandbox` in vendored mode) names the harvest cache.

`just/sandbox/lifecycle/{execute,teardown}.just`,
`just/sandbox/manage/list.just` — read runs-dir from `run_record.py runs-dir`
instead of hardcoding `.sandbox/runs`.

`just/obs.just` — every recipe's DB line re-resolves through
`run_record.py state-root`: when the roster's db is the plain kernel default
and the state root is non-empty, use `<root>/sssf.db`.

`sandbox_mount/host/scaffold.py` — generated `.gitignore` now carries
`sssf/`; the auto-namespacing under `adws/adw_data/local/<key>/` is GONE
(rosters get plain kernel defaults and rely on resolution); banner prints the
`local/<run_id>` branch + the state-root fact.

### Roster

`adws/adw_sssf_config/sssf.meta11.config.yaml` (new, full-unlock) — the
runners' standing rules in its header (no self-commit, no push), `protected_files: []`,
every per-agent `writes:` survives from prior rosters, the documenter writes
`app_docs/`/`docs/`/`**/*.md`/`*.md`.

### Cookbooks + existing app_docs updated

`.claude/skills/sssf-sandbox-orchestrator/cookbooks/{mount_one,local_mode,
teardown_and_reap,observe_and_report,fan_out_n}.md` and
`app_docs/{668e1c2f_local-payload-machinery,ec075aad_issue-tracking,
fd43ce2c_harvest-merge-modes}.md` — `.sandbox/runs` references replaced by the
state-root rule (`<state root>/runs/…`, legacy noted), `local/<run-id>` branch
name used where it changed (`sbx/<run-id>` → `local/<run-id>`), `<state
root>/runs/<id>.watcher.log`, `<state root>/repos/<app>.git` for the harvest
cache.

### Spec + initial write-up from the chain

`specs/17f984ce_state-root-rehoming.md` — the full feature spec (5 design
steps, verification plan).
`app_docs/17f984ce_state-root-rehoming.md` — the chain's own write-up of the
feature (a sibling of this document).

### Hygiene

`sssf.meta8.config.yaml` was already removed in commit `2a8ad90`; verified
with `git ls-files`. `sssf.meta11.config.yaml` is NOT deleted in this change
(its header says "delete when the feature lands" — the commit phase's job).

## How to verify

**Read the resolution rule and pick which test applies.**

```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.meta11.config.yaml \
  uv run sandbox_mount/host/run_record.py state-root
# vendored → empty line
SSSF_CONFIG=sssf.hello-server.local.config.yaml \
  uv run sandbox_mount/host/run_record.py state-root
# local → /Users/you/projects/hello-server/sssf
uv run sandbox_mount/host/run_record.py runs-dir   # state-root + /runs, or legacy
uv run sandbox_mount/host/run_record.py list       # new + legacy deduped, newest first
```

**Local project A and B, kernel tree clean (case (a)).**
Mount + execute on two local scratch rosters:
```bash
SSSF_CONFIG=sssf.A.config.yaml just local mount A-id
SSSF_CONFIG=sssf.A.config.yaml just local execute A-id plan-build "small change"
SSSF_CONFIG=sssf.B.config.yaml just local mount B-id
SSSF_CONFIG=sssf.B.config.yaml just local execute B-id plan-build "small change"
ls A/sssf/runs/ B/sssf/runs/                       # each id lives under its own clone
ls ~/.sssf/apps/                                    # sandbox-only target → goes here
git -C $SSSF_REPO status                           # kernel tree clean (no new files)
git -C A log local/A-id                            # code, specs/, app_docs/ all on the branch
```

**Sandbox with `local_path` (case (b)).**
```bash
just sbx mount <id>                                # gates A–E pass, host-side arming
just sbx lifecycle execute <id> -- plan-build
just sbx lifecycle teardown <id>                   # harvest then destroy
ls <local_path>/sssf/runs/<id>-artifacts <local_path>/sssf/runs/<id>.bundle
just sbx manage harvest <id>                       # merge into the local clone
```

**Sandbox-only fallback (case (c)).** A roster with `app.repo` but no
`app.local_path` resolves to `~/.sssf/apps/<app-key>/`; legacy
`.sandbox/runs/` records still resolve via `get`/`list`.

**Migration (case (d)).** Drop a legacy record + artifacts + bundle into
`.sandbox/runs/`, then:
```bash
SSSF_CONFIG=sssf.<name>.local.config.yaml \
  uv run sandbox_mount/host/run_record.py migrate
# report lines; idempotent on re-run
uv run sandbox_mount/host/run_record.py get <run-id>     # from the new location
# forced failure (unwritable destination) → source intact, exit 1
```

**Kernel-self regression (case (e)).** A vendored run traces/sessions
kernel-side; `state-root` is empty, `runs-dir` is legacy, and
`route_kernel_products` is a no-op (payload == kernel).

## Out of scope

The factory repo, the parked `ref-guard` / `rollback-index` / `deleted_files`
items, deleting `sssf.meta11.config.yaml`.