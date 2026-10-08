# Complete the `just local` payload mode — machinery files

Run `668e1c2f` finishes the **LOCAL payload mode** feature. A previous run
(`36b894b2`) shipped most of it — README, justfile, `just/local.just`,
scaffold, issue tracker, orchestrator cookbook — but its builder was correctly
barred from the five machinery files that wire the feature into the rest of
the kernel. Those edits were rolled back; the unbarred work survived
uncommitted in the working tree and is now part of this change.

This run adds the missing wiring in three small files plus two roster doc
comments, and proves the whole feature end-to-end with eight verification
steps (scaffold → mount → execute → orch resume → ui → kernel-inside refusal
→ sandbox regression → surface).

## What changed

### Payload resolution precedence — `git_helper.payload_root()`

`adws/adw_modules/git_helper.py` — `payload_root()` now resolves in three
modes, with the LOCAL clone winning when set:

1. **`app.local_path` set** — expanded, resolved, **must NOT be inside the
   kernel tree** (a `RuntimeError` with a named error otherwise); if it
   resolves to an existing git repo, that clone is the payload. A `local_path`
   that is set but missing or not yet cloned falls through (cloning is
   `mount`'s job, not the resolver's).
2. **`app.repo` set** and `<factory_root>/<app.path>` is an existing git repo
   → that target clone (sandbox target mode, unchanged).
3. Else → the factory root itself (vendored, unchanged).

The kernel-inside check is the load-bearing piece: `payload_root()` raises
with the exact text `payload_root: app.local_path '<path>' is inside the kernel
tree '<root>' — the kernel is never the payload of an app run; point
local_path at a clone OUTSIDE the kernel`. `just local mount` performs the
same check in shell with the same error wording.

### App config schema — `AppConfig.local_path`

`adws/adw_modules/data_types.py` — `AppConfig` gains one optional field,
`local_path: Optional[str] = None`, documented in the class docstring as the
LOCAL-mode payload (host clone, wins over `repo`/`path`). `AppConfig` is a
plain pydantic `BaseModel` that ignores unknown keys, so every existing
roster continues to load.

### Quality phase — `_app_dir()` follows `payload_root()` in local mode

`adws/adw_modules/quality.py` — `_app_dir()` was resolving to
`run.repo_root / app.path` unconditionally, which in local mode pointed at a
nonexistent `<kernel>/<path>` dir; `_load_checks` would find no manifest and
the quality phase would silently run ZERO checks (a green-looking no-op). The
fix is minimal: when `app.local_path` is set, resolve through `payload_root`
and return that root. The `!= repo_root` guard keeps target and vendored
modes byte-identical (the `local_path`-absent path never calls
`payload_root`). The same change also consolidates the SDLC test check name:
`run_inkwell_quality` and `run_inkwell_tests` now both match the
`TEST_CHECK_NAMES = ("test", "tests")` convention, so scaffolded manifests
(declaring `test` in map form) and the reference inkwell app (declaring
`tests` in list form) both run as the SDLC's deterministic test phase.

### Roster doc comments — both rosters gain the same commented `local_path:`

- `adws/adw_sssf_config/sssf.config.yaml` — commented `local_path:` block
  documenting the LOCAL mode opt-in.
- `adws/adw_sssf_config/sssf.hello.config.yaml` — same commented block,
  kept **absent** so the hello roster remains a sandbox target-mode roster.
  Verification (g) depends on this.

## Files this change touches

| file | role |
| --- | --- |
| `adws/adw_modules/data_types.py` | `AppConfig.local_path` field + docstring |
| `adws/adw_modules/git_helper.py` | `payload_root()` precedence + kernel-inside error |
| `adws/adw_modules/quality.py` | `_app_dir()` follows `payload_root()`; test-name convention |
| `adws/adw_sssf_config/sssf.config.yaml` | commented `local_path:` doc |
| `adws/adw_sssf_config/sssf.hello.config.yaml` | commented `local_path:` doc (kept absent) |

Plus the unbarred work from `36b894b2` that survives in the tree and ships
with this commit:

- `README.md` — new "Local development — `just local`" section + `local`
  command rows in the SSSF_CONFIG table
- `justfile` — `mod local 'just/local.just'`
- `just/local.just` — full local namespace: scaffold, mount, execute, ui,
  doctor, orch (cc|pi)
- `sandbox_mount/host/issue_tracker.py` — `--local` flag on open/close/watch,
  `sssf:local` label, host trace/db reads (no ssh), local-mode provenance
  rows, harvest-status wording, surviving-state text
- `sandbox_mount/host/scaffold.py` — `--preset local`, host clone
  (`clone_local`), `write_roster(..., local_path=)`
- `.claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md` — the
  orchestrator-facing cookbook for the local lane
- `specs/668e1c2f_local-payload-machinery.md` — the spec for this run
- `sssf.meta9.config.yaml` — this run's one-off roster; **deleted after
  verification** per its own header

## How to use it

### Local lane (the new thing)

```sh
just local scaffold                         # interactive: creates repo, clones to host, writes roster
SSSF_CONFIG=sssf.<name>.config.yaml         # in .env or inline
just local doctor                            # preflight + payload resolution
just local mount <run-id>                    # clone-if-missing, run branch sbx/<id>, run record (vm_name=local)
just local execute <run-id> sdlc "<prompt>" # full SDLC, FOREGROUND; commits land on sbx/<id>
just local ui                                # trace visualizer against adws/adw_data/sssf.db
just local orch cc|pi adws/adw_sssf_config/sssf.<app>.config.yaml   # orchestrator
```

Issues open/close exactly like the sandbox lane but are labeled **`sssf:local`**
and carry no VM fields. There is no teardown — `git switch main` in the clone
is the cleanup. Commits land directly on `sbx/<run-id>` in the clone; push
when ready, nothing is harvested or bundled.

### The kernel-inside rule

A roster whose `app.local_path` points inside the kernel tree fails with a
**named error** at two layers — `git_helper.payload_root()` (Python, raised
during chain execution) and `just local mount` (shell, in the mount recipe)
— with identical wording:

```
payload_root: app.local_path '<path>' is inside the kernel tree '<root>' —
the kernel is never the payload of an app run; point local_path at a clone
OUTSIDE the kernel
```

### Sandbox lane (unchanged behavior)

The hello roster stays absent of `local_path`, so `just sbx mount`, the
`sssf.config.yaml` default, and vendored apps (`apps/inkwell`) all continue
to resolve through the unchanged TARGET/VENDORED branches. `payload_root()`'s
target and vendored paths are byte-identical to the prior implementation.

## How to verify it

End-to-end verification (eight steps from the spec, abbreviated; full
acceptance criteria are in `specs/668e1c2f_local-payload-machinery.md` §6):

1. **Scaffold** — piped `just local scaffold` for `sssf-local-test-*`:
   GitHub repo created, host clone present, roster contains `local_path:`,
   finish banner prints the `just local mount` next step.
2. **Mount** — `SSSF_CONFIG=$PWD/sssf.<name>.config.yaml just local mount <id>`
   green; clone on `sbx/<id>`; run record shows `vm_name=local` and a
   `commit_sha`.
3. **Execute** — `just local execute <id> sdlc "<small change>"` green
   end-to-end; the **quality phase actually runs the manifest's checks
   against the local clone** (this is the `_app_dir()` fix — a "no checks"
   note is a FAILURE here); `git log main..sbx/<id>` non-empty; issue closed
   accepted with `sssf:local`.
4. **Orch resume** — `just local orch pi <roster>` derives the session id
   `local-<name>` deterministically (strip `sssf.`/`.config.yaml`,
   sanitize); two non-interactive pi turns on that session id prove memory
   continues.
5. **UI** — `just local ui` serves the visualizer; `curl` the URL it prints;
   kill the process.
6. **Kernel-inside refusal** — a scratch roster whose `local_path` resolves
   inside the kernel tree: `payload_root()` raises the named `RuntimeError`;
   `just local mount <id>` refuses with the same error wording.
7. **Sandbox regression** — hello roster (no `local_path`) goes through
   `just sbx mount` and gates A–E green; precedence probes (Python
   one-liners) confirm all three `payload_root` modes resolve correctly;
   `quality._app_dir` is byte-identical for `local_path`-absent rosters.
8. **Surface** — `just --list local` lists scaffold/mount/execute/ui/doctor/
   orch; every command in the README's new section matches observed
   behavior.

## Notes for the next agent

- `sssf.meta9.config.yaml` was the one-off roster for this run; it was
  deleted after verification (its own header said so). It is **not** in
  `changed_files` because it does not exist afterwards; the deletion is
  reflected in the run summary instead.
- The `payload_root()` precedence uses `Path.is_relative_to` (Python 3.9+)
  for the kernel-inside check — if any caller is on an older Python, that
  is the first place to look.
- The `TEST_CHECK_NAMES` consolidation in `quality.py` is a behavior change
  for scaffolded apps (their `test:` map-form block now runs) and a no-op
  for the reference inkwell (its `tests:` list-form block already ran). If
  a downstream manifest uses a different name, this is the second place to
  look.
- The shell `awk` parsers in `just/local.just` and the Python `_app_config()`
  in `issue_tracker.py` both read `app.local_path` with the same flat
  two-space indentation; if a roster deviates, both layers will silently
  report empty.
