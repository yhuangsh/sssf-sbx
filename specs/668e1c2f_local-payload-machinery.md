# Plan: finish LOCAL payload mode — the five machinery files

## Context

Run 36b894b2's builder implemented most of the LOCAL payload mode feature
(`just local` namespace) but was correctly barred from five machinery files;
those edits were rolled back. The unbarred work SURVIVES uncommitted in the
working tree and must NOT be redone:

- `README.md` (new Local development section, SSSF_CONFIG rows)
- `justfile` (`mod local 'just/local.just'` registered)
- `just/local.just` (NEW: scaffold/mount/execute/ui/doctor/orch — includes its
  own kernel-inside refusal at mount)
- `sandbox_mount/host/issue_tracker.py` (`--local` flag, `sssf:local` label,
  local trace/commit reads)
- `sandbox_mount/host/scaffold.py` (`--preset local`, `clone_local`,
  `write_roster(..., local_path=)`)
- `.claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md` (NEW)

The original feature spec: `specs/36b894b2_local-payload-mode.md` (also at
`adws/adw_data/sessions/36b894b2/context_handoff/plan.md`). This plan covers
ONLY the remaining machinery plus the end-to-end verification of the whole
feature.

## Scope — exactly these files

| file | change |
| --- | --- |
| `adws/adw_modules/data_types.py` | `AppConfig` gains `local_path` |
| `adws/adw_modules/git_helper.py` | `payload_root()` new precedence + kernel-inside named error |
| `adws/adw_modules/quality.py` | `_app_dir()` resolves via `payload_root` in local mode (currently BROKEN in local mode — see §3) |
| `adws/adw_sssf_config/sssf.config.yaml` | commented `local_path:` doc in `app:` block |
| `adws/adw_sssf_config/sssf.hello.config.yaml` | same commented `local_path:` doc (stays unset — sandbox roster) |
| `adws/adw_sssf_config/sssf.meta9.config.yaml` | this run's roster; its header says "Delete when landed" — delete AFTER verification passes (see §5) |

Everything else is out of scope. Do not touch the surviving files unless
verification proves one broken; if so, fix minimally and say so in the report.

## 1. `adws/adw_modules/data_types.py` — `AppConfig.local_path`

In `AppConfig` (~line 346), add one field after `manifest`:

```python
local_path: Optional[str] = None    # LOCAL mode: existing clone of app.repo on the host; wins over repo/path
```

Update the class docstring to name the three payload modes: local (host clone
via `local_path`, the `just local` lane), target (`repo`+`path`, VM clone), and
vendored (no `repo`, payload inside the factory clone at `path`). Note that
`local_path` must point OUTSIDE the kernel tree and that
`git_helper.payload_root()` owns the resolution precedence.

`AppConfig` is a plain pydantic `BaseModel` (extra keys are ignored, not
rejected), so adding the field is safe for every existing roster.

## 2. `adws/adw_modules/git_helper.py` — `payload_root()` precedence

Rewrite `payload_root(app_cfg, factory_root)` with this precedence:

1. **`local_path` set** → expand `~` (`Path(app_cfg.local_path).expanduser()`),
   make absolute/resolve:
   - If the resolved path is inside `factory_root`
     (`resolved.is_relative_to(Path(factory_root).resolve())`) → raise
     `RuntimeError` with a named error, e.g.
     `payload_root: app.local_path '<path>' is inside the kernel tree '<root>' — the kernel is never the payload of an app run; point local_path at a clone OUTSIDE the kernel`.
     This check fires whether or not the path is a git repo.
   - Else if it is an existing git repo (`is_repo(resolved)`) → return it
     (LOCAL mode).
   - Else (set but missing/not yet cloned) → fall through to step 2. Cloning
     is the mount's job, not the resolver's.
2. **`repo` set** and `<factory_root>/<app.path>` is an existing git repo →
   return it (today's target mode, unchanged).
3. Else → `factory_root` (vendored, unchanged).

Update the docstring to describe the three modes and the fall-through rule.
Signature unchanged: callers `adws/adw_plan_build.py`, `adw_simple_sdlc.py`,
`adw_modules/changes.py` need no changes; the RuntimeError propagates and fails
the chain with the named error (intended for verification (f)).

## 3. `adws/adw_modules/quality.py` — local-mode app-dir resolution (BROKEN today)

`_app_dir()` currently returns `run.repo_root / app.path` unconditionally. In
local mode the payload lives outside the kernel at `local_path`, so this
resolves to a nonexistent `<kernel>/<path>` dir, `_load_checks` finds no
manifest, and the quality phase silently runs ZERO checks — a green-looking
no-op. This must be fixed for the SDLC in verification (c) to be real.

Minimal fix, keeping target and vendored modes byte-identical:

```python
def _app_dir(run) -> Path:
    """Where the app under test lives: the local clone in LOCAL mode, else the
    roster's `app.path` under repo root."""
    app = getattr(run.cfg, "app", None)
    if app is not None and getattr(app, "local_path", None):
        from .git_helper import payload_root
        root = payload_root(app, run.repo_root)
        if root != Path(run.repo_root).resolve():
            return root
    path = getattr(app, "path", None) or DEFAULT_APP_PATH
    return run.repo_root / path
```

Notes:
- Local import is unnecessary (git_helper has no cycle with quality); a
  top-level `from .git_helper import payload_root` is fine too — pick one.
- `payload_root` raises the named kernel-inside RuntimeError here too, which
  is correct (f).
- When `local_path` is set but not yet cloned, `payload_root` falls through;
  the `!= repo_root` guard keeps vendored/target behavior exact in that
  transient state.
- Nothing else in quality.py needs changing: `_run_checks` already runs with
  `cwd=_app_dir(run)`, and `_check_dir` anchors artifacts at
  `run.context_handoff_dir` (kernel-side, immune).
- Verify there are no OTHER places that derive the app dir from `app.path`
  that must follow the payload (grep for `app.path` / `DEFAULT_APP_PATH` in
  `adws/`). Adjust only if genuinely broken in local mode; report each.

## 4. Roster doc comments

In BOTH `adws/adw_sssf_config/sssf.config.yaml` and
`adws/adw_sssf_config/sssf.hello.config.yaml`, add to the `app:` block,
keeping the flat two-space style the awk parsers rely on (commented out —
hello stays a sandbox roster; verification (g) depends on that):

```yaml
  # local_path: ~/projects/<app>   # LOCAL mode: an existing clone of app.repo on
                                   # the host. Set AND a git repo -> payload_root
                                   # resolves here (host runs, `just local`); it
                                   # must live OUTSIDE this kernel tree.
```

Default roster: absent = vendored. Hello roster: absent = sandbox target mode.
`local_path` is strictly opt-in.

## 5. This run's roster

`adws/adw_sssf_config/sssf.meta9.config.yaml` is the one-off roster
authorizing this run; its own header says "Delete when landed." AFTER
verification (a)–(h) passes, delete it with `rm` (allowed — it is in scope).
The chain's commit phase owns the commit; report the deletion in
`notes_for_next_agent`, NOT in `changed_files` (which lists only files that
exist afterwards).

## 6. Verification — the WHOLE feature end to end (one feature, not two)

Run all of these for real; evidence goes in the envelope/report.

(a) **scaffold:** `NAME=sssf-local-test-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')`;
drive `printf '%s\n' … | just local scaffold "$NAME"` with piped answers
(create, public, bun, defaults, local_path under `~/projects/$NAME` or `/tmp`).
Assert: GitHub repo created, clone at `local_path` is a git repo, the written
roster (`sssf.$NAME.config.yaml` in the repo root) contains `local_path:`,
finish banner prints `just local mount`. KEEP repo+clone+roster for (b)–(e).

(b) **mount:** `SSSF_CONFIG=$PWD/sssf.$NAME.config.yaml just local mount <id>`
→ green; `git -C <local_path> branch --show-current` = `sbx/<id>`;
`uv run sandbox_mount/host/run_record.py get <id> vm_name` = `local`,
`commit_sha` set.

(c) **execute:** `just local execute <id> sdlc "add a /version endpoint returning {\"version\": \"0.1.0\"} plus a test"`
(adjust to the scaffolded app's stack). Assert: full SDLC green — the quality
phase must actually RUN the manifest's checks against the local clone (this is
the §3 fix; a "declares no checks" note is a FAILURE here);
`git -C <local_path> log main..sbx/<id> --oneline` non-empty; the issue in the
test repo is closed accepted and carries `sssf:local`
(`gh issue view … --json labels,state`).
Then clean up: `gh repo delete "<owner>/$NAME" --yes`, remove the clone and
the roster file from the repo root.

(d) **orch resume:** `SID=local-<name>` derived exactly as the recipe does
(strip `sssf.`/`.config.yaml`, sanitize). Two non-interactive pi turns on that
session id (turn 1 plants a fact, turn 2 recalls it) proving the deterministic
`local-` session continues. Plus: run `just local orch pi <roster>` far enough
to capture the boot banner (exported SSSF_CONFIG, `app.local_path` line,
`resume: … local-<name>`), then interrupt.

(e) **ui:** launch `just local ui` backgrounded, `curl -sf http://localhost:5173`
(and the API port if printed), then kill it.

(f) **kernel immutability:** scratch roster (in /tmp or via env override) whose
`app.local_path` points INSIDE the kernel tree (e.g. `$PWD/tmp-payload`):
- `uv run python -c` calling `payload_root` with that config → assert the
  named RuntimeError text;
- `just local mount <id>` with that roster → refuses with its named error
  (already implemented in `just/local.just` — verify, don't reimplement).

(g) **sandbox regression:** hello roster must still have NO `local_path`.
`just sbx manage doctor` green; `just sbx mount <id>` gates A–E green; teardown
afterwards. Plus a direct precedence probe (python one-liners): `payload_root`
with (i) local_path set+repo → local clone; (ii) no local_path, repo set,
target clone present → target; (iii) neither → factory root. Also confirm
`quality._app_dir` is unchanged for target/vendored rosters (the
`local_path`-absent path never calls payload_root).

(h) **surface:** `just --list local` lists scaffold/mount/execute/ui/doctor/orch;
every command in the README's new section was executed in (a)–(e); README
claims match observed behavior.

## Done means

(a)–(h) demonstrated with evidence; all changes landed BY THIS CHAIN (commit
phase owns the commit — leave the tree dirty, no self-commit); throwaway repo
deleted, throwaway clone and roster removed; `sssf.meta9.config.yaml` deleted
per §5; tree otherwise clean. `changed_files` lists only files that exist
afterwards; deletions go in summary/notes.

## Out of scope

Everything not listed above — the factory repo, parked items, extending
`permissions.py` into the payload, the surviving files' internals (unless
proven broken by verification).
