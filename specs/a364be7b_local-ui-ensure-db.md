# Fix `just local ui` on a fresh project: ensure the trace db exists

## Problem

On a project whose trace db doesn't exist yet (no chain has run — the Tracer
creates `sssf.db` lazily on first write), `just local ui` launches the
visualizer, which **exits immediately**:

```
[sssf] sssf.db not found at <path>
```

(`.claude/skills/sssf/apps/visualizer/server/db.ts:67-73` — the `TraceDb`
constructor throws when the file is missing. That behavior stays; out of
scope.) A developer's FIRST command after mounting must not fail: an empty
project is a valid state and must render as an empty sessions list.

The sandbox lane already solved this exact problem: `sandbox_mount/guest/
provision.sh` step **7/9 "trace db"** (lines ~304-337) creates the empty db
with the correct schema via a uv PEP-723 inline script that imports
`adw_modules.tracer.Tracer` (DDL is all `CREATE TABLE IF NOT EXISTS` +
additive migrations, so it's idempotent). The local lane has no equivalent.
This fix ports that pattern to the host, as ONE helper with TWO callers.

## Changes

### 1. NEW `sandbox_mount/host/ensure_trace_db.py` — the shared helper

A self-contained uv PEP-723 script (same dependency set as provision.sh's
inline script). Contract:

- Usage: `uv run sandbox_mount/host/ensure_trace_db.py <db-path>`
- Resolves `<db-path>`: `expanduser`, and if relative, against the repo root
  (just recipes run from the repo root via `set working-directory := '..'`,
  but resolve explicitly so the helper is cwd-independent).
- Instantiates `Tracer(db, db.parent / "sessions" / "events.jsonl")` — this
  mkdirs the db parent, creates the db with the full schema
  (`CREATE TABLE IF NOT EXISTS` + `MIGRATIONS`), and creates the events
  file's parent dir (the sessions dir). Passing the sessions dir itself as
  the events-file parent leaves no stray session behind — same trick as
  provision.sh. `db.parent / "sessions"` matches both provision.sh
  (`data_dir/sessions`, and for the hello roster `data_dir == db.parent`)
  and the visualizer, which derives `sessionsDir` as a sibling of the db
  (`server/db.ts`: `resolve(dirname(path), "sessions")`).
- Closes `tracer.conn` before exiting (clean WAL checkpoint).
- **All say-lines go to STDERR.** This is a hard requirement: caller #2 is
  `local_ui.py`, whose stdout is `eval`'d by the just recipe and must carry
  only the three `KEY=value` lines.
- Idempotent: record `existed = db.is_file()` first; print
  `→ trace db: initialized fresh <db> (empty — no runs yet)` when it was
  missing, `→ trace db: <db> (already present — schema verified)` when not.
  Tracer's DDL makes opening an existing db a no-op.
- Exit 0 on success, 1 on usage error.

Skeleton (builder may adjust wording, keep the contract):

```python
#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pydantic", "python-dotenv", "pyyaml", "rich"]
# ///
"""ensure_trace_db.py — create a project's sssf.db with the full Tracer schema.

One implementation, two callers: sandbox_mount/host/local_ui.py (before
launching the visualizer) and just/local.just's mount recipe (after its
preflight). Idempotent — Tracer's DDL is CREATE TABLE IF NOT EXISTS plus
additive migrations. All prose to stderr: local_ui.py's stdout is eval'd.
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]  # sandbox_mount/host/ -> root
sys.path.insert(0, str(REPO_ROOT / "adws"))      # the `uv run adws/adw_*.py` import root

from adw_modules.tracer import Tracer

def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: uv run sandbox_mount/host/ensure_trace_db.py <db-path>", file=sys.stderr)
        return 1
    db = Path(argv[0]).expanduser()
    if not db.is_absolute():
        db = (REPO_ROOT / db).resolve()
    existed = db.is_file()
    tracer = Tracer(db, db.parent / "sessions" / "events.jsonl")
    tracer.conn.close()
    if existed:
        print(f"→ trace db: {db} (already present — schema verified)", file=sys.stderr)
    else:
        print(f"→ trace db: initialized fresh {db} (empty — no runs yet)", file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

### 2. `sandbox_mount/host/local_ui.py` — ensure-db step before launch

- Add `import subprocess`.
- Add an `ensure_db(db: Path)` helper: if `db.is_file()`, return immediately
  (existing db untouched — no subprocess spawn, no added latency on the
  common path). Otherwise run the shared helper:

  ```python
  result = subprocess.run(
      ["uv", "run", str(REPO_ROOT / "sandbox_mount" / "host" / "ensure_trace_db.py"), str(db)],
  )
  if result.returncode != 0:
      print(f"[local ui] trace db init failed (exit {result.returncode})", file=sys.stderr)
      sys.exit(1)
  ```

  (Nested `uv run` from inside a `uv run` script is fine — uv resolves the
  child script's own PEP-723 deps. Cold resolve is ~3s once per machine, the
  same cost provision.sh pays and warms; it only ever hits on a project's
  first-ever `ui`.)
- Call it in `main()` immediately after `db = resolve_db(roster)` (before the
  port-file / health-check work). Ordering is safe: a live visualizer for
  this db implies the db exists (the visualizer exits without it), so the
  already-running fast path never spawns the helper. The helper's say-line
  lands on stderr ahead of the port chatter.

### 3. `just/local.just` — mount caller + cosmetic single-URL

**mount recipe** — after the working-tree-clean preflight check and before
the run-branch section, resolve the roster's `observability.db` with the same
flat two-space awk idiom used for the `app:` block, then invoke the SAME
helper:

```bash
    # ── trace db: an armed project has its db from the start. Same helper the
    # ui recipe uses (via local_ui.py) — one implementation, two callers.
    # Idempotent: an existing db is opened, schema-verified, and left alone.
    APP_DB=$(awk '
      /^observability:[[:space:]]*$/ { o=1; next }
      /^[^[:space:]]/                { o=0 }
      o && /^[[:space:]]+db:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    uv run sandbox_mount/host/ensure_trace_db.py "${APP_DB:-adws/adw_data/sssf.db}"
```

(`print $2` drops any inline `#` comment; the default mirrors
`ObservabilityConfig.db`'s default in `adws/adw_modules/data_types.py:342`.)

**ui recipe** — cosmetic: delete this line after `eval "$OUT"`:

```bash
    echo "→ visualizer: http://localhost:$UI_PORT  (api :$API_PORT, db: $DB)"
```

`local_ui.py` already prints the URL exactly once in BOTH paths — the
already-running path (`→ visualizer already running: http://localhost:...`,
exit 10, recipe maps to 0) and the launch path (`→ visualizer:
http://localhost:...`). The recipe's echo is the second print. After removal:
exactly one URL line per invocation.

## Out of scope (do not touch)

- The visualizer's missing-db exit behavior (`server/db.ts`) — the kernel now
  guarantees existence.
- `sandbox_mount/guest/provision.sh`, `just/sandbox/**` — the VM visualizer
  path is unchanged; (d) below is a regression proof, not a change.
- The pre-existing unrelated worktree deletion
  `D adws/adw_sssf_config/sssf.meta10.config.yaml` (was dirty before this
  chain; leave it alone, do not stage it).

## Verification (all four required; "done" = a–d demonstrated)

Setup note: `SSSF_CONFIG` is exported in this session's environment as
`adws/adw_sssf_config/sssf.hello.config.yaml`. The `ui` recipe runs vite in
the FOREGROUND, so every `just local ui` below runs in the background with
output captured, gets polled via the API, then is killed (kill the process
group, or `pkill -f` the vite port and `server/index.ts`; make sure no
orphaned visualizer holds 4620/4621 between steps — check with the ui recipe
itself, which detects a live instance).

### (a) fresh-project path — empty db is initialized, empty list served

Use a scratch roster + scratch data dir under `/tmp` (zero repo pollution;
`adws/adw_data/local/` is gitignored but a scratch roster inside
`adws/adw_sssf_config/` would not be):

1. `cp adws/adw_sssf_config/sssf.hello.config.yaml /tmp/sssf.freshui.config.yaml`
   and edit two lines: `defaults.data_dir: /tmp/sssf-freshui` and
   `observability.db: /tmp/sssf-freshui/sssf.db` (absolute paths —
   `local_ui.resolve_db` honors them).
2. Assert `/tmp/sssf-freshui/sssf.db` does not exist.
3. `SSSF_CONFIG=/tmp/sssf.freshui.config.yaml just local ui` in background,
   stderr+stdout tee'd to a log.
4. Assert the log contains `→ trace db: initialized fresh /tmp/sssf-freshui/sssf.db`.
5. Read the port from the log's URL line (or `/tmp/sssf-freshui/ui.port`),
   then assert:
   - `curl -s http://127.0.0.1:$((UI_PORT+1))/api/health` reports db
     `/tmp/sssf-freshui/sssf.db`;
   - `curl -s http://127.0.0.1:$((UI_PORT+1))/api/sessions` returns `[]`
     (empty sessions list — the fresh project renders).
6. Kill the visualizer + vite; `rm -rf /tmp/sssf.freshui /tmp/sssf.freshui.config.yaml`.

### (b) populated path — ui serves the run in the list

The hello project's db `adws/adw_data/local/hello/sssf.db` is ALREADY
populated — this very chain is session `a364be7b` in its `sessions` table
(verified: `select adw_id, status from sessions` → `a364be7b|running`). No
new execute is needed to get a real run row:

1. `just local ui` (default roster) in background.
2. `curl -s .../api/sessions` returns a non-empty list containing an entry
   with `adw_id == "a364be7b"`.
3. Assert the log does NOT contain `initialized fresh` (existing db untouched).
4. Keep this instance running for (c), or kill and relaunch there.

### (c) idempotent second call — URL exactly once, exit 0

1. With the (b) visualizer running, run `just local ui` a second time,
   capturing combined stdout+stderr.
2. Assert exit code 0 (recipe maps the script's exit-10 already-running to 0).
3. Assert `grep -c 'http://localhost' ` on the captured output is exactly `1`.
4. Also assert the db file was not modified (checksum/mtime before vs after).
5. Kill the visualizer; confirm ports 4620/4621 are free again.

### (d) sandbox regression — `just sbx mount` gates A–E green

Nothing in the sandbox lane changed; prove it:

1. `just sbx mount <fresh-run-id>` with the hello roster
   (`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`; it has
   `app.repo` and no `local_path` → sandbox TARGET mode). This chains
   create → fill → setup → observe.
2. Assert setup's gate output shows `A PASS`, `B PASS`, `C PASS`, and the
   D/E pass lines (gates live in `just/sandbox/lifecycle/setup.just`), and
   that observe's visualizer bound :4600 (provision step 7/9 created the VM
   db, unchanged by this work).
3. `just sbx lifecycle teardown <run-id>` afterwards — the VM was created
   solely for this regression; don't leave it billing. (Teardown is normally
   an explicit operator decision; here the chain created the VM, so the
   chain cleans it up.)

This step boots a real exe.dev VM — budget several minutes.

## Files touched

- NEW `sandbox_mount/host/ensure_trace_db.py`
- `sandbox_mount/host/local_ui.py` (ensure-db call + `import subprocess`)
- `just/local.just` (mount ensure-db block; ui recipe duplicate-echo removal)
- `specs/a364be7b_local-ui-ensure-db.md` (this plan)

## Commit lane

The chain's commit phase owns the commit. Leave the work dirty in the tree;
do not commit. `changed_files` lists only files that exist afterwards.
