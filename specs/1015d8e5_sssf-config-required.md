# Plan: Make SSSF_CONFIG required — remove every silent roster fallback

## Problem

Every roster consumer in the kernel silently falls back to the shipped
placeholder roster `adws/adw_sssf_config/sssf.config.yaml` when `SSSF_CONFIG`
is unset:

- root `justfile`: `config := env_var_or_default("SSSF_CONFIG", "adws/adw_sssf_config/sssf.config.yaml")` (line 13; dead variable — modules do not inherit it, but it documents the wrong contract)
- `just/adws.just`: same `env_var_or_default` for the `config` used by all 12 chain recipes
- shell recipes reading `ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"`:
  - `just/sandbox/mount.just` (arming preflight)
  - `just/sandbox/lifecycle/create.just` (VM tag derivation)
  - `just/sandbox/lifecycle/fill.just` (the roster that is shipped verbatim)
  - `just/sandbox/lifecycle/teardown.just` (artifact set)
  - `just/sandbox/manage/harvest.just` (repo the bundle comes from)
  - `just/sandbox/manage/mod.just` (`doctor` arming visibility)
- `sandbox_mount/host/roster_keys.sh`: `ROSTER="${1:-${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}}"`
- all 12 `adws/adw_*.py` chains: `parser.add_argument("--config", default="adws/adw_sssf_config/sssf.config.yaml")` (and matching `main(..., config="<same default>")` signatures)

A developer who forgot `SSSF_CONFIG` silently gets the placeholder roster —
the proven source of the `apps/your-app` mount failure.

## Goal

1. No silent default anywhere. Every roster-consuming command fails FAST on
   the host when `SSSF_CONFIG` is unset or empty, with ONE consistent named
   error (exact text below). The file
   `adws/adw_sssf_config/sssf.config.yaml` STAYS in the repo as a template —
   it is just never implicitly selected.
2. Deliberate non-fallbacks that must NOT change:
   - `just/sandbox/lifecycle/setup.just`: empty `CONFIG` arg resolving to the
     shipped per-sandbox copy at `/home/exedev/sssf_config.yaml` (the
     ssh-carries-no-environment mechanism — NOT a silent default).
   - `just/sandbox/lifecycle/execute.just`: forwarding of that same path.
   - FILL ships `$SSSF_CONFIG` verbatim — so FILL must require it (rule 1).
   - `just sbx run agent` / `run cmd` (record-driven), `observe` (reads the
     shipped copy remotely), `manage list` (records only): untouched.
3. README gains a "Which commands need SSSF_CONFIG" reference near the Arming
   section, plus the requirement statement with the exact error text.

## The one error message (single source of truth)

Used verbatim by the shell guard, the just guard recipes, and the python
chains:

```
SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming.
```

Exit codes: shell guard exits `1`; python chains exit `2` (argparse-adjacent).
All print to stderr. What matters is the message text is byte-identical
everywhere — keep it in exactly two owned copies (the guard script and
`adw_modules/utils.py`), with the just recipes delegating to the script.

## Design

Three enforcement layers, applied consistently:

### Layer A — shared shell guard (new file)

`sandbox_mount/host/require_sssf_config.sh` (new, chmod +x):

```bash
#!/usr/bin/env bash
# require_sssf_config.sh — print the active roster path or fail with THE named error.
#
# There is no default roster any more: adws/adw_sssf_config/sssf.config.yaml is
# a template, never implicitly selected. Every roster-consuming command routes
# through here (directly or via a just `_require-sssf-config` recipe) so the
# error text lives in exactly one place.
#
# Usage: ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
set -uo pipefail
if [ -z "${SSSF_CONFIG:-}" ]; then
    echo "SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming." >&2
    exit 1
fi
printf '%s\n' "$SSSF_CONFIG"
```

Note: no `set -e` needed; deliberate `set -u` only. Keep the same comment
style as `roster_keys.sh` (header block naming callers).

### Layer B — just recipes

- Root `justfile`: DELETE the dead `config := env_var_or_default(...)` line
  (line 13) and its comment (line 12). Modules never saw it; replace with a
  one-line comment: `# SSSF_CONFIG is REQUIRED — there is no default roster. Each consuming module enforces it (see sandbox_mount/host/require_sssf_config.sh).`
- `just/adws.just`:
  - change `config := env_var_or_default("SSSF_CONFIG", "adws/adw_sssf_config/sssf.config.yaml")`
    to `config := env_var_or_default("SSSF_CONFIG", "")`
  - add a private guard recipe (recipes run with cwd = repo root because of
    `set working-directory := '..'`, and the whole repo ships into the
    sandbox, so the relative path resolves on host and in-box):
    ```
    # fail fast when SSSF_CONFIG is unset — THE named error, one copy
    _require-sssf-config:
        @sandbox_mount/host/require_sssf_config.sh > /dev/null
    ```
  - make EVERY chain recipe depend on it: `prompt *ARGS: _require-sssf-config`,
    `ask`, `scout`, `plan`, `build`, `plan-build`, `build-test`,
    `build-review`, `quality`, `document`, `sdlc`,
    `plan-build-test-quality`, `simple-sdlc` (13 recipes). The guard runs
    before the body, so `--config ""` never reaches python from this lane;
    python still guards (Layer C) for direct invocation.
  - do NOT add the dep to the `default` listing recipe.
- `just/obs.just`: add the same `_require-sssf-config` recipe and make every
  query recipe depend on it: `rosters`, `sessions`, `phases`, `tail`,
  `procs`, `kill`, `ui`. (The prompt's table puts `just obs` on the
  needs-it side — uniform requirement, verified in (a) with `just obs tail`.)
  Not `default`.
- Shell recipes — replace each `ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"`
  with `ROSTER=$(sandbox_mount/host/require_sssf_config.sh)`, and update the
  adjacent comments that say "same fallback":
  - `just/sandbox/mount.just` — at the top of the preflight block (already
    first thing; fails before any `just sbx lifecycle create` call → no VM).
  - `just/sandbox/lifecycle/create.just` — MOVE the guard up into the
    preflight `for bin in ssh python3` block, BEFORE the run record is
    created (today the roster read sits in the 2b tag block, after the
    record write; requiring it must not leave orphan records). Keep the
    existing `[ -f "$ROSTER" ]` guard in 2b using the now-required `$ROSTER`.
    Tag fallback to `sssf` when the roster has no `app.repo` STAYS — that is
    a tag default, not a roster default.
  - `just/sandbox/lifecycle/fill.just` — replaces the `ROSTER=` line in the
    "per-app input" block (recipe already `cd`s to the justfile directory).
  - `just/sandbox/lifecycle/teardown.just` — at the very top of the recipe
    body (after flag parsing), BEFORE the run-record check, so
    `just sbx lifecycle teardown anything` with unset `SSSF_CONFIG` fails
    with THE named error, not "no run record".
  - `just/sandbox/manage/harvest.just` — replaces the `ROSTER=` line.
  - `just/sandbox/manage/mod.just` (`doctor`) — at the top of the recipe:
    `ROSTER=$(sandbox_mount/host/require_sssf_config.sh) || exit 1` (a
    doctor with no roster has nothing to preflight; the named error IS the
    report). The later `chk "roster provider keys set"` line and the arming
    visibility block reuse `$ROSTER`.
- `sandbox_mount/host/roster_keys.sh` — change resolution to:
  ```bash
  ROSTER="${1:-}"
  if [ -z "$ROSTER" ]; then
      ROSTER=$("$(dirname "$0")/require_sssf_config.sh")
  fi
  ```
  and update the Usage comment (`default: $SSSF_CONFIG — REQUIRED, no fallback`).
  Explicit-arg callers (fill passes `"$ROSTER"`) are unchanged.
- DO NOT TOUCH: `setup.just`, `execute.just`, `observe.just`, `run/mod.just`,
  `manage/list.just` (verified: none of them read `SSSF_CONFIG` today except
  via the deliberate shipped-copy mechanism, and that stays).

### Layer C — python chains (12 files: adws/adw_prompt, adw_scout, adw_plan,
adw_build, adw_plan_build, adw_build_test, adw_build_review, adw_quality,
adw_document, adw_plan_build_test, adw_plan_build_test_quality,
adw_simple_sdlc)

- `adws/adw_modules/utils.py`: add
  ```python
  CONFIG_REQUIRED_MSG = (
      "SSSF_CONFIG is not set — point it at your roster (add "
      "'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, "
      "or export it inline). See README -> Arming."
  )

  def require_config(config: str | None) -> str:
      """Return the roster path or die with THE named error (same text as
      sandbox_mount/host/require_sssf_config.sh — keep the two copies in sync)."""
      if not config:
          print(CONFIG_REQUIRED_MSG, file=sys.stderr)
          sys.exit(2)
      return config
  ```
  (add `import sys` if missing).
- In each of the 12 chains:
  - `parser.add_argument("--config", default="adws/adw_sssf_config/sssf.config.yaml")`
    → `parser.add_argument("--config", default=None, help="roster path — required (SSSF_CONFIG or explicit)")`
  - after `parse_args()`: `args.config = utils.require_config(args.config)`
    before `main(...)` (all 12 already import `utils`; `adw_simple_sdlc.py`
    too — verify its import name, it uses the same `from adw_modules import ...` pattern).
  - `main(..., config: str = "adws/adw_sssf_config/sssf.config.yaml", ...)`
    → drop the default (`config: str`) — only the file's own `__main__`
    calls it (verified: chains never import each other's `main`).
  - docstring usage lines: `[--config adws/adw_sssf_config/sssf.config.yaml]`
    → `--config <roster>  (required unless the just recipe supplies it)`.

### Docs

- `.env.sample`: move/annotate the `SSSF_CONFIG` line — it is no longer an
  "Optional override": change the comment to
  `# SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml   # REQUIRED — no default; roster-consuming commands fail fast without it`.
  Leave it commented (the user must choose their roster); do NOT edit `.env`
  (its `# SSSF_CONFIG=...` line stays commented — verification (a) depends on
  the var being unset).
- `README.md`:
  - "Prerequisites + arming checklist" step 2: drop "(default:
    `adws/adw_sssf_config/sssf.config.yaml`)" → "Point `SSSF_CONFIG` at your
    roster — **required, there is no default**; every roster-consuming
    command below fails fast without it."
  - Add a new section right after the checklist (near Arming), titled
    `## Which commands need SSSF_CONFIG`, containing the exact error text in
    a code block and this table (VERIFY each row against the recipes before
    writing it — the reviewer re-checks):

    | command | needs `SSSF_CONFIG`? | why |
    | --- | --- | --- |
    | `just sbx mount` | yes | preflight parses the roster's `app:` block |
    | `just sbx lifecycle create` | yes | derives the VM tag from `app.repo` |
    | `just sbx lifecycle fill` | yes | ships THIS roster verbatim to `/home/exedev/sssf_config.yaml` |
    | `just sbx lifecycle teardown` | yes | `app:` block picks the artifact set |
    | `just sbx manage doctor` | yes | roster provider-key preflight |
    | `just sbx manage harvest` | yes | `app:` block picks the repo the bundle comes from |
    | `just adw …` (all chains) | yes | `--config` comes from `SSSF_CONFIG` |
    | `just obs …` | yes | same requirement, enforced by the shared guard |
    | `uv run adws/adw_*.py …` direct | yes | `--config` is required |
    | `just sbx lifecycle setup` | no | gates against the per-sandbox copy FILL shipped at `/home/exedev/sssf_config.yaml` (ssh carries no environment; optional `CONFIG` arg overrides) |
    | `just sbx lifecycle execute` | no | forwards that same shipped path unless you pass `CONFIG` |
    | `just sbx lifecycle observe` | no | reads the shipped copy remotely |
    | `just sbx run agent` / `run cmd` | no | record-driven; the sandbox pi reads what FILL shipped |
    | `just sbx manage list` | no | reads run records only |

  - Integration section (a): the sentence "run with `SSSF_CONFIG=<your
    roster>`" already implies it; make it explicit that the run fails fast
    without it.

## Verification (all four required; (a) and (d) are cheap, (b) is the real mount)

(a) **Unset fails fast** — ensure `.env` has `SSSF_CONFIG` commented and run
each from the repo root with the var unset; each must exit non-zero within
seconds and print THE named error, and `ssh exe.dev ls --json` must show no
new VM (and `.sandbox/runs/` no new record from the `create` probe):

```sh
env -u SSSF_CONFIG just sbx mount probe-unset          # named error in preflight
env -u SSSF_CONFIG just sbx manage doctor              # named error
env -u SSSF_CONFIG just sbx lifecycle teardown probe   # named error (before record check)
env -u SSSF_CONFIG just sbx lifecycle create probe     # named error (before record/VM)
env -u SSSF_CONFIG just adw sdlc "x"                   # named error via _require-sssf-config
env -u SSSF_CONFIG just obs tail abc123                # named error
env -u SSSF_CONFIG uv run adws/adw_plan_build_test.py "x"   # named error, exit 2
```

Also confirm the NOT-needing lanes still work unset (no VM needed):
`env -u SSSF_CONFIG just sbx manage list` succeeds; `just sbx run cmd` /
`observe` / `setup` have no guard added (verify by reading +, if a live box
exists from (b), exercising them before teardown).

(b) **Armed path unaffected** —
`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount reqcfg-check`
passes setup gates A–E (which exercise the shipped
`/home/exedev/sssf_config.yaml` — covering (c)'s setup lane), then
`just sbx lifecycle teardown reqcfg-check` completes clean. Optionally,
before teardown, `just sbx lifecycle execute reqcfg-check "..."` with an
empty CONFIG arg to prove execute's shipped-path forwarding (else cover (c)
by reading).

(c) Covered by (b) as noted, or by reading `setup.just`/`execute.just` —
their `CONFIG → /home/exedev/sssf_config.yaml` logic must be byte-identical
before and after.

(d) **README table matches reality** — re-grep the recipes for
`require_sssf_config` / `_require-sssf-config` and confirm each table row.

## Gotchas

- `just` evaluates `:=` backtick assignments EAGERLY (verified: a backtick
  assignment runs even for recipes that never reference it). Do NOT use a
  backtick guard in the root justfile — it would break `setup`/`run`/
  `observe`/`list`, which must work unset. The private-recipe-dependency
  pattern in Layer B is deliberate: it scopes the guard to exactly the
  recipes that need it.
- `just adw`'s bare `default` recipe stays unguarded so
  `just --list adw` (used by `doctor`'s "adw layer resolves" check) still
  resolves... note doctor now requires `SSSF_CONFIG` anyway; keep `default`
  unguarded regardless.
- Inside the sandbox, `just adw …` is invoked as
  `just --shell bash --shell-arg -c adw …` from `~/app`; the guard recipe's
  relative path `sandbox_mount/host/require_sssf_config.sh` resolves because
  FILL clones the whole repo there and `execute` always passes an explicit
  `--config` anyway.
- Keep `chmod +x` on the new script; follow the repo's comment density
  (every touched block explains WHY, matching existing style).

## Out of scope

The factory repo, parked items, changing WHICH rosters exist, deleting or
renaming `adws/adw_sssf_config/sssf.config.yaml`.
