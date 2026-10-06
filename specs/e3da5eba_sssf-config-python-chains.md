# Plan: Finish SSSF_CONFIG-required — python chains (Layer C)

## Context

Run 1015d8e5 (spec: `specs/1015d8e5_sssf-config-required.md`) implemented the
whole SSSF_CONFIG-required change shell-side and in README, but its builder was
barred from the python chains and those edits were rolled back. The working
tree ALREADY holds the surviving shell-side work (uncommitted): `justfile`,
`just/adws.just`, `just/obs.just`, `just/sandbox/**`, `sandbox_mount/host/
{roster_keys.sh,require_sssf_config.sh}` (guard is untracked), `.env.sample`,
`README.md` (with the `## Which commands need SSSF_CONFIG` section at line 136).

**This run's remaining scope is ONLY the python chains.** The session roster
(`adws/adw_sssf_config/sssf.meta7.config.yaml`) authorizes the builder to write
exactly the 12 `adws/adw_*.py` chain files, `adws/adw_modules/utils.py`, and
its own roster file. Touch NOTHING else — not `just/*`, not `sandbox_mount/*`,
not README, not `.env`/`.env.sample`, and **not `adw_modules/agents.py`** (its
`load_config(path: str = "adws/adw_sssf_config/sssf.config.yaml")` default
stays; it is unreachable dead code once `require_config` gates every caller,
and it is outside the authorized writes).

## The one error message (byte-identical everywhere)

Single source of truth is `sandbox_mount/host/require_sssf_config.sh` (shell,
exit 1). The python copy lives in `adw_modules/utils.py` (exit 2,
argparse-adjacent). Text must match byte-for-byte:

```
SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming.
```

## Edits

### 1. `adws/adw_modules/utils.py` — add the shared helper

Add `import sys` (not currently imported; `os` already is). Append:

```python
CONFIG_REQUIRED_MSG = (
    "SSSF_CONFIG is not set — point it at your roster (add "
    "'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, "
    "or export it inline). See README -> Arming."
)


def require_config(config: str | None) -> str:
    """Return the roster path or die with THE named error.

    Explicit --config wins; otherwise SSSF_CONFIG from the environment (this
    module already load_dotenv()s, so an armed .env counts for direct script
    runs). Message is byte-identical to
    sandbox_mount/host/require_sssf_config.sh — keep the two copies in sync.
    Exit 2 (argparse-adjacent) where the shell guard exits 1.
    """
    roster = config or os.environ.get("SSSF_CONFIG", "").strip()
    if not roster:
        print(CONFIG_REQUIRED_MSG, file=sys.stderr)
        sys.exit(2)
    return roster
```

Watch the string-concatenation seams: `(add "` ends with a space, `to .env, `
ends with a space — the joined result must be byte-identical to the shell
line, em-dash and trailing period included.

### 2. The 12 chain files — same three edits in each

Files: `adw_prompt.py`, `adw_scout.py`, `adw_plan.py`, `adw_build.py`,
`adw_plan_build.py`, `adw_build_test.py`, `adw_build_review.py`,
`adw_quality.py`, `adw_document.py`, `adw_plan_build_test.py`,
`adw_plan_build_test_quality.py`, `adw_simple_sdlc.py`.

Per file:

a. **argparse** — change
   `parser.add_argument("--config", default="adws/adw_sssf_config/sssf.config.yaml")`
   to
   `parser.add_argument("--config", default=None, help="roster path — required (SSSF_CONFIG or explicit)")`.

b. **after `args = parser.parse_args()`, before the `main(...)` call** — insert
   `args.config = utils.require_config(args.config)`.
   All 12 already do `from adw_modules import ... utils` (verified for
   adw_prompt, adw_scout, adw_simple_sdlc; grep-confirm the rest while
   editing). `sys` is already imported in every chain (they all
   `sys.exit(main(...))`).

c. **`main` signature** — `config: str = "adws/adw_sssf_config/sssf.config.yaml"`
   becomes `config: str` (drop the default). Only each file's own `__main__`
   block calls `main` — chains never import each other's `main` (verified in
   1015d8e5). Note the multi-line signatures in `adw_prompt.py` and
   `adw_document.py` wrap `config` onto a continuation line.

d. **module docstring Usage line** — `[--config adws/adw_sssf_config/sssf.config.yaml]`
   becomes `[--config <roster>]` plus one note line under Usage:
   `--config / SSSF_CONFIG is REQUIRED — there is no default roster; with neither, the chain fails fast with the named error (README -> Which commands need SSSF_CONFIG).`

### Why the env fallback in `require_config` is correct

- `just/adws.just` passes ` --config $SSSF_CONFIG` when set and NOTHING when
  unset (by design — see its header comment), so the unset lane reaches the
  chain with `config=None`; with `.env` also unset, `require_config` fails
  fast with the named error. That is verification (a)'s `just adw sdlc "x"`.
- The sandbox `execute` lane appends an explicit trailing `--config`; argparse
  keeps the LAST occurrence, so the shipped-copy path still wins.
- Direct `uv run adws/adw_*.py` with an armed `.env` (utils.load_dotenv)
  works without a flag — matching the README row "needs SSSF_CONFIG: yes".

## Verification (the change is ONE change — run all four)

Precondition: `.env` line 37 (`# SSSF_CONFIG=...`) must STAY commented. Do not
edit `.env`.

(a) **Unset fails fast, host-side, consistent error.** From the repo root,
each command below must exit non-zero within seconds, print THE named error
on stderr, and create no VM (confirm with `ssh exe.dev ls --json` and that
`.sandbox/runs/` gains no record from the create probe):

```sh
env -u SSSF_CONFIG just sbx mount probe-unset
env -u SSSF_CONFIG just sbx manage doctor
env -u SSSF_CONFIG just sbx lifecycle teardown probe
env -u SSSF_CONFIG just sbx lifecycle create probe
env -u SSSF_CONFIG just adw sdlc "x"
env -u SSSF_CONFIG just obs tail abc123
env -u SSSF_CONFIG uv run adws/adw_plan_build_test.py "x"   # exit 2 expected
```

Byte-identity spot check (outputs must be the same single line):

```sh
diff <(env -u SSSF_CONFIG sandbox_mount/host/require_sssf_config.sh 2>&1 || true) \
     <(env -u SSSF_CONFIG uv run adws/adw_plan_build_test.py "x" 2>&1 || true)
```

Negative control (must still work unset): `env -u SSSF_CONFIG just sbx manage list`.

(b) **Armed path passes end to end.**
`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount reqcfg-check`
— fresh VM, setup gates A–E pass (they exercise the shipped
`/home/exedev/sssf_config.yaml`, which covers (c)'s setup lane). Optionally,
before teardown, `just sbx lifecycle execute reqcfg-check "<trivial cmd>"`
with no CONFIG arg to prove execute's shipped-path forwarding. Then
`just sbx lifecycle teardown reqcfg-check` completes clean.

(c) **setup/execute shipped-config lanes** — covered by (b)'s gates A–E, plus
`git diff --stat` must show NO changes to `just/sandbox/lifecycle/setup.just`
or `execute.just`.

(d) **README table matches recipes** — re-grep for the guard:
`grep -rn "require_sssf_config\|_require-sssf-config" just/ sandbox_mount/`
must hit exactly: mount, lifecycle/{create,fill,teardown}, manage/{mod,harvest},
obs.just, roster_keys.sh, require_sssf_config.sh — and each `yes`/`no` row in
README's table (line ~136) must agree. The reviewer re-verifies this row by
row.

## Gotchas

- Do not "fix" `adw_modules/agents.py` — it is outside the authorized writes
  and its default is unreachable after this change.
- `just adw`'s recipes invoke `uv run adws/adw_x.py{{cfg}} "$@"` — the guard
  is the python `require_config`, there is intentionally no
  `_require-sssf-config` dependency in `just/adws.just` (unlike obs.just).
- Exit-code asymmetry is deliberate: shell guard 1, python 2. Only the
  MESSAGE must be identical.
- Keep the repo's comment density/style in edited blocks (explain WHY).
- The commit phase owns the commit — leave the tree dirty, list only files
  that exist afterwards in changed_files.

## Out of scope

Everything not listed above: just/shell/README files (already landed),
`agents.py`, deleting/renaming rosters, the factory repo. (The session roster
`sssf.meta7.config.yaml` says "Delete when landed" — that decision belongs to
the operator/commit phase, not the builder.)
