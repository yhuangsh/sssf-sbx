# SSSF_CONFIG is now required — shell, python, and README in lockstep

## Summary

There is no default roster any more. `adws/adw_sssf_config/sssf.config.yaml`
is a template, never implicitly selected. Every command that consumes a roster
fails fast on the host, before any VM is created, with **one** named error
when `SSSF_CONFIG` is unset. The shipped per-sandbox copy at
`/home/exedev/sssf_config.yaml` (written by `fill`) is the deliberate
exception — `setup`, `execute`, and `observe` keep reading that path because
ssh carries no environment.

## Why it matters

Two failure modes the old default hid:

1. A blank repo with no `.env` quietly pointed every run at the template,
   which has `app.path: apps/your-app` and no `app.repo:` — so the run
   looked vendored, then blew up partway through with an error that named
   the template, not the missing roster.
2. A run that *did* have a roster in `.env` could still drift: a `just adw
   sdlc` invocation that bypassed `.env` (subshell, sandbox env) fell back
   to the template and committed nothing useful, silently.

The fix is a single shared guard (`sandbox_mount/host/require_sssf_config.sh`)
plus a python twin (`adws/adw_modules/utils.require_config`) with a
byte-identical message. Exit codes differ (shell 1, python 2) by design —
only the text is locked.

## The shared error (byte-identical in both copies)

```
SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming.
```

If you change it, change both copies. The python module ships the constant
as `CONFIG_REQUIRED_MSG` and the shell script inlines the same string; a
grep will surface any drift:

```sh
grep -n "SSSF_CONFIG is not set" sandbox_mount/host/require_sssf_config.sh adws/adw_modules/utils.py
```

## Files that carry it

### Shell side (was landed by run 1015d8e5, kept)

- `sandbox_mount/host/require_sssf_config.sh` — **the** guard. `echo`s the
  active roster path on stdout, or prints the named error on stderr and
  exits 1. Used by every roster-consuming host recipe either directly or
  via a `_require-sssf-config` dependency.
- `sandbox_mount/host/roster_keys.sh` — drops its own default-fallback;
  when called with no argument and `SSSF_CONFIG` is unset, delegates to
  the shared guard. Explicit-arg callers (FILL passes `"$ROSTER"`) are
  unchanged.
- `justfile` — removes the root `config` variable. The variable was
  unreachable from imported modules anyway; removing it eliminates the
  silent-fallback illusion.
- `just/adws.just` — `config := env_var_or_default("SSSF_CONFIG", "")` and
  `cfg := if config == "" { "" } else { " --config " + config }`. Recipes
  expand `{{cfg}}` so a missing `SSSF_CONFIG` adds **no** `--config` flag
  at all (rather than `--config ""`), letting the chain's own
  `require_config` fail fast with the named error.
- `just/obs.just` — adds a `_require-sssf-config` recipe (guard wired
  via `> /dev/null` so only stderr surfaces) and makes every query
  (`sessions`, `phases`, `tail`, `procs`, `kill`, `rosters`, `ui`)
  depend on it. The bare `default:` listing stays unguarded so
  `just --list obs` still works.
- `just/sandbox/mount.just`,
  `just/sandbox/lifecycle/{create,fill,teardown}.just`,
  `just/sandbox/manage/{mod,harvest}.just` — each replaces its
  `${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}` line with
  `ROSTER=$(sandbox_mount/host/require_sssf_config.sh)`. The guard runs
  *before* any work that would create state (mount's preflight before
  VM create, fill before parse-and-ship, teardown before the run-record
  check, harvest before bundle, doctor at the top so its named error
  *is* the report).
- `.env.sample` — replaces the commented `SSSF_CONFIG=...` example with
  an uncommented-required block ("no default roster") and a pointer to
  README's table.

### Python side (this run)

- `adws/adw_modules/utils.py` — adds `import sys`, the
  `CONFIG_REQUIRED_MSG` constant, and `require_config(config)` which
  resolves explicit `--config` then falls back to `SSSF_CONFIG` from
  `os.environ` (utils already `load_dotenv()`s so an armed `.env`
  counts for direct script runs). Returns the roster path or prints
  the named error to stderr and `sys.exit(2)`s.
- All 12 chain entrypoints
  (`adws/adw_prompt.py`, `adws/adw_scout.py`, `adw_plan.py`,
  `adw_build.py`, `adw_build_review.py`, `adw_build_test.py`,
  `adw_plan_build.py`, `adw_plan_build_test.py`,
  `adw_plan_build_test_quality.py`, `adw_quality.py`,
  `adw_document.py`, `adw_simple_sdlc.py`) — same three edits in each:
  1. argparse `--config` default drops from the template path to `None`
     with help text `"roster path — required (SSSF_CONFIG or explicit)"`;
  2. `main`'s signature drops the default: `config: str =
     "adws/adw_sssf_config/sssf.config.yaml"` → `config: str`;
  3. right after `args = parser.parse_args()`, before the `main(...)`
     call, insert `args.config = utils.require_config(args.config)`.
     For `adw_prompt.py` and `adw_document.py` the `main(...)` call
     reorders so `config` is the second positional (it follows
     `prompt`). Module docstring `Usage:` lines are updated and a
     "REQUIRED — there is no default roster" note is added.
- `adws/adw_sssf_config/sssf.meta7.config.yaml` — the session roster
  that authorizes this run's builder to edit exactly the python files
  above. Says so in plain English at the top. Delete when landed.

### Documentation (this run, completing 1015d8e5)

- `README.md` — adds the `## Which commands need SSSF_CONFIG` table
  under step 2 of Arming. Each row lists the recipe, whether it needs
  `SSSF_CONFIG`, and why. The `yes` rows are exactly the ones that
  route through the guard. The `no` rows (`setup`, `execute`,
  `observe`, `run agent`, `run cmd`, `manage list`) all read the
  shipped per-sandbox copy or run-records, not the env. The summary
  sentence above the table states the rule and the exact error.

## How the lanes coexist

- `just adw …` passes ` --config $SSSF_CONFIG` only when set; with
  neither flag nor env, the chain hits `utils.require_config` and
  fails fast. With an armed `.env`, the env-fallback inside
  `require_config` makes the direct script run work without a flag —
  matching the table row "needs SSSF_CONFIG: yes".
- `just sbx lifecycle execute <run> "<cmd>"` may pass an explicit
  `--config` for the in-sandbox invocation. Argparse keeps the LAST
  occurrence; the chain's pre-flight check still sees the
  `SSSF_CONFIG`-set roster (good), and the explicit `--config` reaches
  the sandbox (good).
- `setup`, `execute`, `observe` read `/home/exedev/sssf_config.yaml`
  verbatim because ssh carries no environment. They are deliberately
  not in the guard's call graph — they aren't consumers of
  `SSSF_CONFIG`, they consume the file `fill` shipped.

## How to verify

Run all four lanes; the change is one, not four.

**(a) Unset fails fast, host-side, consistent error.** Each command below
exits non-zero within seconds, prints the named error on stderr, and
creates no VM (confirm `ssh exe.dev ls --json` is unchanged and no run
record is added to `.sandbox/runs/` by the create probe):

```sh
env -u SSSF_CONFIG just sbx mount probe-unset
env -u SSSF_CONFIG just sbx manage doctor
env -u SSSF_CONFIG just sbx lifecycle teardown probe
env -u SSSF_CONFIG just sbx lifecycle create probe
env -u SSSF_CONFIG just adw sdlc "x"
env -u SSSF_CONFIG just obs tail abc123
env -u SSSF_CONFIG uv run adws/adw_plan_build_test.py "x"   # exit 2
```

Byte-identity check between shell and python copies:

```sh
diff <(env -u SSSF_CONFIG sandbox_mount/host/require_sssf_config.sh 2>&1 || true) \
     <(env -u SSSF_CONFIG uv run adws/adw_plan_build_test.py "x" 2>&1 || true)
```

Negative control (must still work unset): `env -u SSSF_CONFIG just sbx manage list`.

**(c) Armed end-to-end.** With
`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`:

```sh
just sbx mount reqcfg-check           # gates A–E pass (covers setup lane)
just sbx lifecycle execute reqcfg-check "<trivial cmd>"   # shipped-path wins
just sbx lifecycle teardown reqcfg-check
```

**(d) README table ↔ recipes.** `grep -rn "require_sssf_config\|_require-sssf-config" just/ sandbox_mount/`
must hit exactly: mount, lifecycle/{create,fill,teardown},
manage/{mod,harvest}, obs.just, roster_keys.sh, require_sssf_config.sh.
Each `yes`/`no` row in the README table must agree.

## Out of scope (intentionally untouched)

- `adws/adw_modules/agents.py` — its `load_config(path: str =
  "adws/adw_sssf_config/sssf.config.yaml")` default is unreachable
  dead code once `require_config` gates every caller. Leaving it
  alone keeps this run inside its authorized fileset.
- Renaming or deleting `sssf.config.yaml` (still a template).
- Removing `sssf.meta7.config.yaml` after landing — that decision
  belongs to the operator/commit phase.