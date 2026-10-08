# RESUME f0492719: namespace the shipped hello roster (per-project local isolation)

## Context — why this is a one-file edit

Run f0492719 shipped the whole local-isolation feature (per-project trace
db + data_dir, per-project visualizer port, serve-port awareness — spec
`specs/f0492719_local-isolation-ports.md`). Every code/script change is in the
tree and verified — I re-verified during planning:

- `just/sandbox/lifecycle/observe.just` emits `OBS_DB_REL` from the roster (line ~114)
- `sandbox_mount/guest/provision.sh` step "7/9 trace db" prefers
  `/home/exedev/sssf_config.yaml` over the kernel default (lines ~326-328)
- `just/sandbox/lifecycle/teardown.just` builds `TAR_PATHS` with `$DB_REL` (line ~93)
- `sandbox_mount/host/issue_tracker.py` has `_roster_db_rel()` (line ~63) used at
  all three db paths (~359, ~377, ~393)
- `.gitignore` covers `adws/adw_data/local/` (line ~151)
- `sandbox_mount/host/local_ui.py` and `serve_ports.py` exist and are wired into
  `just/local.just` (ui/mount/doctor)
- `just/obs.just`, `README.md`, the orchestrator cookbook are modified

The ONE missing piece is the roster edit itself: the prior builder claimed it
twice, the reviewer caught it, and `adws/adw_sssf_config/sssf.hello.config.yaml`
on disk still has `data_dir: adws/adw_data` and `db: adws/adw_data/sssf.db`.
Until the roster is namespaced, every other roster-aware consumer resolves the
hello project back into the kernel's db — the feature is inert.

## The edit — `adws/adw_sssf_config/sssf.hello.config.yaml` ONLY

Two value changes plus one comment. **Every other field and every existing
comment stays byte-intact.** Do not reformat, reorder, or touch
`adws/adw_sssf_config/sssf.config.yaml` (the kernel roster keeps
`adws/adw_data` — it IS the kernel project's own trace).

1. `defaults.data_dir` (currently, ~line 45):
   ```yaml
   data_dir: adws/adw_data          # runtime home: {data_dir}/sessions/{adw_id}/{agent_name}/
   ```
   →
   ```yaml
   # Per-project local isolation (spec f0492719): this roster's runtime state
   # lives under adws/adw_data/local/<key>, key = the roster filename middle part.
   data_dir: adws/adw_data/local/hello  # runtime home: {data_dir}/sessions/{adw_id}/{agent_name}/
   ```
   (One added comment naming the per-project layout — the two lines above count
   as that comment; keep the original trailing comment's meaning, exact wording
   of the added lines is the builder's choice as long as it names the
   `local/<key>` layout.)

2. `observability.db` (currently, ~line 48):
   ```yaml
   db: adws/adw_data/sssf.db        # tracer writes here directly; the UI polls it
   ```
   →
   ```yaml
   db: adws/adw_data/local/hello/sssf.db  # tracer writes here directly; the UI polls it
   ```

Use `edit` (find/replace), not a YAML round-trip — the file's comments must
survive, which is exactly why scaffold.py does this line-wise too.

## Static verification (cheap, do first)

- `git diff adws/adw_sssf_config/sssf.hello.config.yaml` shows ONLY the two
  value changes and the added comment line(s) — nothing else in the file moved.
- Parse + assert:
  ```bash
  uv run --with pyyaml python3 -c "
  import yaml; c = yaml.safe_load(open('adws/adw_sssf_config/sssf.hello.config.yaml'))
  assert c['defaults']['data_dir'] == 'adws/adw_data/local/hello', c['defaults']['data_dir']
  assert c['observability']['db'] == 'adws/adw_data/local/hello/sssf.db', c['observability']['db']
  print('roster namespaced OK')"
  ```
- `git diff --stat adws/adw_sssf_config/sssf.config.yaml` is empty (kernel roster untouched).

## Behavioral verification — the real proof

Record the kernel's own db identity BEFORE anything runs, and again AFTER:

```bash
sha256sum adws/adw_data/sssf.db; stat -c %s adws/adw_data/sssf.db   # before
# ... run the flow ...
sha256sum adws/adw_data/sssf.db; stat -c %s adws/adw_data/sssf.db   # after — must be identical
```

(The kernel db is WAL-mode; if sha differs only because of a `-wal` flush,
prove byte-equivalence another way — but a sandbox run should not touch the
host kernel db at all, so identical sha/size is the expected outcome. Note:
`sssf.db-shm`/`-wal` exist alongside; checksum all three if you want to be
strict, but the mandate is the main db file.)

### Strongest proof: fresh sandbox mount with gates A–E green

VM creation goes through `ssh exe.dev new` (`just/sandbox/lifecycle/create.just`
line ~87) — there is no local `exe` binary on this host, so first probe
availability cheaply: `ssh -o BatchMode=yes -o ConnectTimeout=5 exe.dev ls`.
If that answers, run the mount:

```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount <run-id>
```

IMPORTANT: `require_sssf_config.sh` prints `$SSSF_CONFIG` verbatim and the
recipes open it relative to the repo root — use the full relative path
`adws/adw_sssf_config/sssf.hello.config.yaml`, not the bare basename from the
prompt.

The mount chain is preflight → create → fill → setup (provisions, then host-side
gates A–E — `just/sandbox/lifecycle/setup.just`) → observe. Gates A–E must be
green (`[setup] GATE PASSED`). Then, on the VM (`ssh <vm>.exe.xyz`), assert:

1. `ls -la '$HOME/app/adws/adw_data/local/hello/sssf.db'` — EXISTS. Provision
   step 7/9 initializes it from the FILL-shipped roster, so it must exist
   before any chain runs.
2. It has tracer tables and real trace rows from the gate runs (gates C/D/E
   run pi inside the sandbox with the roster):
   `sqlite3 '$HOME/app/adws/adw_data/local/hello/sssf.db' "select adw_id from sessions;"`
   — non-empty.
3. The kernel-path db on the VM was NOT created:
   `ls '$HOME/app/adws/adw_data/sssf.db'` — must NOT exist (provision no longer
   initializes via the kernel default; no in-VM chain writes there).
4. The observe step passed against the roster path (it resolves
   `OBS_DB="$HOME/app/$OBS_DB_REL"` from the shipped roster — its own success
   is evidence the namespaced db is the live one).

Then tear down: `just sbx lifecycle teardown <run-id>` — never leave a VM
running.

### Fallback if exe.dev is unreachable from this environment

Say so EXPLICITLY in the report (the operator runs the mount), and prove the
behavioral consequence locally instead:

```bash
SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml \
  just local execute <run-id> simple-sdlc "<small prompt>"
```

Then assert: `adws/adw_data/local/hello/sssf.db` exists on the host with this
run's session row (`sqlite3 ... "select adw_id from sessions;"` shows ONLY this
run), and the before/after kernel-db sha/size are identical. Also verify by
inspection that provision.sh step 7/9, observe.just, teardown.just and
issue_tracker.py already resolve the roster path (they do — line numbers above).

## Definition of done

- Hello roster namespaced (two values + one layout comment; nothing else in the
  file changed).
- Mount gates A–E green, trace rows proven in
  `adws/adw_data/local/hello/sssf.db` (VM or, if exe.dev is down, host-local),
  kernel-path db absent on the VM / kernel db on the host byte-identical
  before↔after.
- Any VM created is torn down.
- The chain's commit phase owns the commit — leave the tree dirty.
  `changed_files` lists only files that exist afterwards (expect exactly
  `adws/adw_sssf_config/sssf.hello.config.yaml`).

## Out of scope / do NOT touch

- Everything else from f0492719 — already in the tree.
- `adws/adw_sssf_config/sssf.config.yaml` (kernel roster keeps `adws/adw_data`).
- `sssf.meta10.config.yaml` (untracked, repo root) — leftover scratch from a
  prior session's verification. Do not edit, do not commit it, do not delete it.
- Scratch fixtures belong in /tmp, never in the repo.
- The known hello-server `checks:` map-vs-list caveat documented in the roster
  (affects only the in-sandbox SDLC test phase, not mount/gates A–E) — not this
  run's problem.
