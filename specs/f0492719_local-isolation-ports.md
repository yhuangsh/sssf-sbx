# Local-mode isolation: per-project trace db + data_dir, per-project visualizer port, serve-port awareness

## Problem

Every local project traces into the kernel's single `adws/adw_data/sssf.db`
(interleaved sessions, one mixed visualizer) and every local `just local ui`
fights over the same ports (api :4600, vite :4601). Per-VM this was fine
(sandbox mode); with multiple local projects on one host it is broken.

## Design (per the prompt — isolation is ROSTER DATA)

- **Project key** = roster filename middle part: `sssf.<key>.config.yaml` →
  `<key>`; the bare `sssf.config.yaml` → `kernel`. The same rule works for
  scaffolded rosters, which land in the repo ROOT as `sssf.<name>.config.yaml`
  (scaffold.py writes there, not into `adws/adw_sssf_config/`).
- Each non-kernel roster namespaces its runtime state **as data**:
  `defaults.data_dir: adws/adw_data/local/<key>` and
  `observability.db: adws/adw_data/local/<key>/sssf.db`. No code change is
  needed for the separation itself — `adw_modules/tracer.py:104` already
  `ensure_dir`s the db parent, `runner.py:54` builds the session dir from
  `data_dir`, and `permissions.py:139` grants `data_dir` writes from config.
- The kernel's own `adws/adw_sssf_config/sssf.config.yaml` KEEPS
  `adws/adw_data` (it is the kernel project's own trace).
- Visualizer port is stable per project, recorded in a `ui.port` file next to
  the project's db (i.e. `adws/adw_data/local/<key>/ui.port` — which is exactly
  `$(dirname "$db")/ui.port`, and stays sane for the kernel at
  `adws/adw_data/ui.port`). The recorded port **P is the user-facing vite
  (UI) port; the API server uses P+1**. Allocation: first pair (P, P+1) both
  free, scanning upward from **4620**.
- App serve-port awareness is a read-only check over all local rosters; it
  warns, never blocks. The kernel cannot rebind an app's port — the warning
  plus corrective instructions is the contract.

## Current-state facts the builder can rely on (verified during planning)

- Visualizer server (`.claude/skills/sssf/apps/visualizer/server/index.ts`):
  `PORT` env (default 4600), db from `--db` / `SSSF_DB` (see `server/db.ts`
  `resolveDbPath`), and `GET /api/health` returns
  `{ ok, db, journal_mode, sessions }` — **`db` is the resolved absolute db
  path**, which is exactly what the idempotency check and verification (b)
  need. `SssfDb.sessionsDir` derives from the db's parent, so the prompts
  endpoint keeps working under a namespaced data_dir.
- `vite.config.ts`: dev port hardcoded 4601, but `bunx vite --port <P>
  --strictPort` overrides it; the `/api` proxy target reads
  `process.env.PORT` at config load, so `PORT=<api> bunx vite --port <ui>
  --strictPort` wires the pair without editing vite.config.ts.
- `require_sssf_config.sh` prints `$SSSF_CONFIG` or dies with THE named error.
- The established host-script idiom is a PEP-723 uv script with
  `dependencies = ["pyyaml"]` (see `issue_tracker.py`, and the in-VM probe
  inside `just/sandbox/lifecycle/observe.just`).
- `.gitignore` today covers `adws/adw_data/sessions/` and `sssf.db*`
  (unanchored) but NOT `adws/adw_data/local/**` — verified with
  `git check-ignore`: `adws/adw_data/local/hello/sessions/foo` and
  `.../ui.port` are NOT ignored. A `.gitignore` line is required.
- Sandbox-lane hardcoded `adws/adw_data/sssf.db` consumers that MUST become
  roster-aware or gate (e) regresses when the hello roster moves its db:
  - `just/sandbox/lifecycle/observe.just` — `OBS_DB='$HOME/app/adws/adw_data/sssf.db'`
  - `sandbox_mount/guest/provision.sh` step "7/9 trace db" — the init script
    calls `load_config()` with NO argument, i.e. the kernel default roster,
    not the FILL-shipped `/home/exedev/sssf_config.yaml`
  - `just/sandbox/lifecycle/teardown.just` — `TAR_PATHS="specs app_docs
    adws/adw_data/sssf.db run.log"` (~line 84)
  - `sandbox_mount/host/issue_tracker.py` — `VM_DB` (line 57),
    `_trace()` local `host_db` (~line 372), `_artifact_db` (~line 356)
- On the VM, chains run with `--config /home/exedev/sssf_config.yaml`
  (execute.just), so the in-VM tracer already follows the roster's
  `observability.db`; only the consumers above lag.

## Changes, file by file

### 1. `adws/adw_sssf_config/sssf.hello.config.yaml` (edit)

- `defaults.data_dir:` → `adws/adw_data/local/hello` (keep the trailing
  comment shape).
- `observability.db:` → `adws/adw_data/local/hello/sssf.db`.
- `adws/adw_sssf_config/sssf.config.yaml` is NOT touched.

### 2. `.gitignore` (edit)

Add under the `# sssf runtime` block:

```
# Local-mode per-project state: namespaced dbs, session dirs, ui.port files
adws/adw_data/local/
```

### 3. `sandbox_mount/host/scaffold.py` (edit `write_roster`)

The roster body is a line-copy of the hello template, so after change (1) it
would carry `local/hello` for every app. In `write_roster`, after computing
the final roster filename (the rename path can change `<name>` → the key must
follow the FINAL roster name), rewrite the two lines in `body`:

- the `  data_dir: adws/adw_data/...` line → `  data_dir: adws/adw_data/local/<key>`
- the `  db: adws/adw_data/...` line → `  db: adws/adw_data/local/<key>/sssf.db`

where `<key>` = roster filename with the `sssf.` prefix and `.config.yaml`
suffix stripped. Do it line-wise (match on the stripped leading key, preserve
indentation), NOT with a YAML round-trip — the file's comments must survive.
Extend the existing post-generation `yaml.safe_load` validation block to
assert `defaults.data_dir == f"adws/adw_data/local/{key}"` and
`observability.db == f"adws/adw_data/local/{key}/sssf.db"`. Add one line to
the summary/finish output noting the namespaced trace dir. Sandbox preset
rosters get the namespacing too — harmless per-VM and keeps one code path.

### 4. NEW `sandbox_mount/host/local_ui.py` (PEP-723 uv script)

Header: `requires-python = ">=3.10"`, `dependencies = ["pyyaml"]`. Stdlib
`socket` + `urllib.request` for port/health probes. Usage:

```
uv run sandbox_mount/host/local_ui.py <roster-path>
```

Behaviour:

1. **Key**: basename; strip `sssf.` prefix and `.config.yaml` suffix; empty
   result → `kernel`.
2. **Db**: `yaml.safe_load(roster)` → `observability.db`, default
   `adws/adw_data/sssf.db`; relative paths resolve against the repo root
   (`Path(__file__).resolve().parents[2]`); print the absolute path.
3. **Port file**: `<db parent>/ui.port`, holding one integer P (UI port; API
   is P+1).
4. **Freeness**: try `socket.bind(("0.0.0.0", port))` without SO_REUSEADDR;
   a pair (P, P+1) is usable only if BOTH bind.
5. **Idempotency**: if the file exists, GET
   `http://127.0.0.1:{P+1}/api/health` (urllib, ~1.5s timeout). On a 200 whose
   JSON `db` equals our resolved db path → print
   `→ visualizer already running: http://localhost:{P} (api :{P+1}, db: <db>)`
   and exit **10** (recipe maps 10 → exit 0).
6. **Conflict**: file exists, idempotency check failed, and (P or P+1) is
   held → stderr named warning:
   `[local ui] WARNING: recorded port P for project '<key>' is held by a process that is not our visualizer — moving to P' (recorded in <port file>)`
   then pick the next free pair scanning upward from `max(P+2, 4620)`, update
   the file.
7. **First use / recorded pair free**: pick the first free pair from 4620
   upward (or reuse the recorded pair); `mkdir -p` the parent and write P.
8. **Stdout contract** (the recipe `eval`s it): exactly three
   `shlex.quote`d assignments — `DB=…`, `UI_PORT=…`, `API_PORT=…`. All human
   prose and warnings go to **stderr**. Exit 0 = proceed to start; 10 =
   already running; 1 = usage/resolution error.

### 5. `just/local.just` (edit)

- **`ui` recipe** (replace the hardcoded body, ~lines 207-215):
  ```bash
  ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
  OUT=$(uv run sandbox_mount/host/local_ui.py "$ROSTER") || {
      rc=$?
      if [ "$rc" -eq 10 ]; then exit 0; fi   # already running; script printed the URL
      exit "$rc"
  }
  eval "$OUT"
  echo "→ visualizer: http://localhost:$UI_PORT  (api :$API_PORT, db: $DB)"
  cd .claude/skills/sssf/apps/visualizer
  bun install
  (SSSF_DB="$DB" PORT="$API_PORT" bun run server/index.ts &)
  PORT="$API_PORT" bunx vite --port "$UI_PORT" --strictPort
  ```
  Note the `set -euo pipefail` + `$(...)` interaction: capture-then-check as
  shown so exit 10 survives. Update the recipe comment.
- **`mount` recipe**: after the manifest-present validation, add a
  non-blocking serve-port report:
  `uv run sandbox_mount/host/serve_ports.py || true`
  (warnings print; mount never fails on them). Mention in the final printf
  only if natural — not required.
- **`doctor` recipe**: add a section that runs
  `uv run sandbox_mount/host/serve_ports.py` and passes its output through;
  it is WARN-only — it must NOT set `ok=1`.

### 6. NEW `sandbox_mount/host/serve_ports.py` (PEP-723 uv script, pyyaml)

The serve-port awareness check used by doctor and mount:

1. **Roster set**: glob `adws/adw_sssf_config/sssf.*.config.yaml` AND
   repo-root `sssf.*.config.yaml` (scaffold writes there; the prompt names
   only the config dir, but excluding scaffolded rosters would make the check
   blind to the lane's own output). Dedupe. (Include a plain
   `sssf.config.yaml` in each dir too; it simply has no `local_path` today.)
2. Per roster: key from the filename rule; `yaml.safe_load`; skip rosters
   without `app.local_path`. `manifest = app.manifest or "sssf.app.yaml"`;
   manifest path = `expanduser(local_path)/manifest`; missing file → a printed
   note (not a warning). Parse the manifest; `serve.port` absent → note
   "no serve:" and skip.
3. **Port map** (always printed):
   `  <key>  serve.port <P>  (<manifest path>)`.
4. **Collision** (same port declared by ≥2 projects) — stderr/stdout warning
   naming BOTH projects and BOTH manifests:
   ```
   WARNING [serve-port] collision: port <P> declared by '<key1>' (<manifest1>) and '<key2>' (<manifest2>)
     either stop the other project's server, or change serve.port in <manifest>, or run yours with PORT=<free> if the app honors it
   ```
5. **Live-bound** (`socket.connect_ex(("127.0.0.1", P)) == 0`):
   ```
   WARNING [serve-port] port <P> declared by '<key>' is currently bound on this host — if that server is not <key>'s own, either stop the other project's server, or change serve.port in <manifest>, or run yours with PORT=<free> if the app honors it
   ```
6. Exit **0 always** (warnings are the contract); non-zero only on usage
   error. When the map is empty print one line saying no local rosters found.

### 7. `just/obs.just` (edit — roster-aware db)

Every query recipe hardcodes `adws/adw_data/sssf.db`. Since every recipe
already depends on `_require-sssf-config` (`$SSSF_CONFIG` is in the
environment), resolve the db per recipe with the file's existing awk idiom:

```bash
DB=$(awk '
  /^observability:[[:space:]]*$/ { o=1; next }
  /^[^[:space:]]/                { o=0 }
  o && /^[[:space:]]+db:[[:space:]]/ { print $2; exit }
' "$SSSF_CONFIG")
DB=${DB:-adws/adw_data/sssf.db}
```

then `sqlite3 "$DB" …` in `sessions`, `phases`, `tail`, `procs`, `kill`, and
`SSSF_DB={{invocation_directory()}}/"$DB"` in `ui`. Update the header comment
and the `ui` comment. (This keeps `obs` correct for the kernel roster too —
its roster still says `adws/adw_data/sssf.db`.)

### 8. `just/sandbox/lifecycle/observe.just` (edit — roster-aware OBS_DB)

Extend the existing in-VM uv probe (the heredoc that already parses
`/home/exedev/sssf_config.yaml`) with:

```python
emit("OBS_DB_REL", (cfg.get("observability") or {}).get("db") or "adws/adw_data/sssf.db")
```

and replace the hardcoded `OBS_DB='$HOME/app/adws/adw_data/sssf.db'`
assignment after the `eval "$APP_ENV"` with `OBS_DB="\$HOME/app/$OBS_DB_REL"`
(keep it VM-expanded, matching the `APP_DIR` idiom two lines down). The
missing-db guard and SSSF_DB start then follow the roster automatically.

### 9. `sandbox_mount/guest/provision.sh` (edit step "7/9 trace db")

The init script's `load_config()` no-arg call reads the kernel default
roster. Change to prefer the FILL-shipped roster:

```python
roster = "/home/exedev/sssf_config.yaml"
cfg = load_config(roster if Path(roster).is_file() else "adws/adw_sssf_config/sssf.config.yaml")
```

so the initialized db path matches the roster the VM's chains will run with.

### 10. `just/sandbox/lifecycle/teardown.just` (edit)

`$ROSTER` is already resolved at the top of the recipe. Add the same
observability-db awk as (7), default `adws/adw_data/sssf.db`, and build
`TAR_PATHS="specs app_docs $DB_REL run.log"` in place of the hardcoded path
(~line 84). The tar is relative to the factory root on the VM, so the
artifact lands at `.sandbox/runs/<id>-artifacts/<db_rel>` on the host.

### 11. `sandbox_mount/host/issue_tracker.py` (edit — three db paths)

Add one helper:

```python
def _roster_db_rel() -> str:
    roster = os.environ.get("SSSF_CONFIG", "").strip()
    if roster and Path(roster).is_file():
        try:
            db = (yaml.safe_load(Path(roster).read_text()) or {}).get("observability") or {}
            rel = db.get("db")
            if rel:
                return str(rel)
        except Exception:
            pass
    return "adws/adw_data/sssf.db"
```

(pyyaml is already a declared dep; everything here stays best-effort.) Use it
in:

- `_trace()` local branch: `host_db = REPO_ROOT / _roster_db_rel()` (~line 372)
- the VM branch: replace the `VM_DB` constant use with
  `f"/home/exedev/app/{_roster_db_rel()}"` (keep the constant as the fallback
  the helper already encodes, or re-point the constant's consumers — pick one
  and keep it tidy)
- `_artifact_db()`: `RUNS_DIR / f"{run_id}-artifacts" / _roster_db_rel()`
  (must match teardown's new tar path from (10)).

### 12. `README.md` (edit)

In the `## Local development — `just local`` section, add a subsection
**`### Local projects: isolation and ports`** documenting:

- Layout: project key from the roster filename; each non-kernel roster owns
  `adws/adw_data/local/<key>/` (trace db `sssf.db`, `sessions/`, `ui.port`);
  the kernel roster keeps `adws/adw_data/`.
- Port rules: `just local ui` records a stable UI port in `ui.port`,
  allocated from 4620 upward; the API runs on port+1; a re-run against a
  live instance prints the URL and exits 0; a port held by something that is
  not our visualizer triggers the named WARNING and an auto-bump.
- Serve-port awareness: `just local doctor` (and `just local mount`, as a
  warning) prints the per-project `serve.port` map; the exact WARNING texts
  for declared collisions and live-bound ports, with the corrective options
  ("either stop the other project's server, or change serve.port in
  <manifest>, or run yours with PORT=<free> if the app honors it").
- Fix the now-stale comment in the local-lane command listing:
  `# the trace visualizer, against the local adws/adw_data/sssf.db` → per-project db.

### 13. `.claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md` (edit)

Update lines ~94-95 (`just local ui` serves "the local trace db
(`adws/adw_data/sssf.db`)") to describe the per-project db and the recorded
port, and that `just obs …` follows the roster. Historical `app_docs/*.md`
records are NOT rewritten.

## Verification (for real — this is the chain's definition of done)

Run all of these; keep outputs as evidence. Scratch fixtures go in /tmp or
are untracked root rosters — never commit fixtures.

**(a) Isolation.** Two rosters: the shipped hello roster plus a scratch copy
`sssf.scratch.config.yaml` (repo root, untracked) with
`data_dir`/`db` → `local/scratch` and `local_path` pointing at a second local
clone of the app (or a scratch dir armed per the local mount rules). For
each: `SSSF_CONFIG=<roster> just local execute <run-id> simple-sdlc "<small
prompt>"`. Then assert: `adws/adw_data/local/hello/sssf.db` and
`adws/adw_data/local/scratch/sssf.db` both exist, and
`sqlite3 <db> "select adw_id from sessions;"` shows each db contains ONLY its
own run's session(s) — no interleaving.

**(b) Two UIs, distinct ports, own dbs.** Background a `just local ui` per
roster (different SSSF_CONFIG). Assert: distinct recorded ports in the two
`ui.port` files; `curl -s localhost:<api>/api/health` on EACH api port
returns `ok:true` and a `db` field naming that project's own db. Kill both
afterwards.

**(c) Port conflict.** Hold a port (e.g. `python3 -m http.server <P>`) and
write `<P>` into project scratch's `ui.port`. Run `just local ui` for
scratch: expect the named `[local ui] WARNING … moving to …`, the file
updated, and the UI serving on the new port while hello's UI from (b) still
serves. Also re-run `just local ui` for a live project: expect the
"already running" line and exit 0, no second server.

**(d) Serve-port collision.** Two rosters with `local_path` set whose
manifests both declare `serve.port: 4501` (scratch clone dirs are fine). Run
`just local doctor`: the WARNING names BOTH projects and the corrective
options; doctor's exit status is unchanged by it. Run `just local mount` on
one and confirm the same warning prints and mount proceeds.

**(e) Sandbox regression.** `SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml
just sbx mount <run-id>` — gates A–E green, and on the VM
`ls $HOME/app/adws/adw_data/local/hello/sssf.db` exists and observe's
visualizer serves it (the `[3/6] obs` step passes against the roster path).
If exe.dev is unavailable in this environment, say so explicitly in the
report, verify (8)/(9)/(10) by inspection + a local run of the modified
provision init snippet, and leave the full mount for the operator. Tear down
any VM created.

**(f) README** subsection landed and matches the implemented warning texts
byte-for-byte.

## Out of scope

- The factory repo, parked items.
- Rewriting historical `app_docs/*.md` / `specs/*.md`.
- Auto-rebinding app serve ports (the warning is the contract).

## Notes

- All recipes here run `set -euo pipefail`; capture-then-check command
  substitution wherever a non-zero exit is meaningful (see the `ui` sketch).
- Keep the flat two-space YAML style in rosters — `mount.just`,
  `manage/mod.just`, `local.just` parse them with awk, not YAML.
- The chain's commit phase owns the commit; leave the tree dirty.
- `changed_files` in the envelope lists only files that exist afterwards.
