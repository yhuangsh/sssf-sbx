# Plan: fail-fast arming preflight for `just sbx mount` (unarmed kernel late-failure defect)

## Defect

On a fresh clone the default roster (`adws/adw_sssf_config/sssf.config.yaml`) ships
`app.path: apps/your-app` as a placeholder and the repo has **no `apps/` dir**
(confirmed: `ls apps` → No such file or directory). `just sbx mount <id>` therefore
pays the full VM create + fill cost and dies only INSIDE the VM at provision step
5/9: `[provision] app.path 'apps/your-app' does not exist under /home/exedev/app`.
`just sbx manage doctor` false-greens the same state.

## Fix — three parts, three files

### 1. Host-side preflight — `just/sandbox/mount.just`

Add a preflight block at the TOP of the `mount` recipe body, BEFORE the
`just sbx lifecycle create "{{RUN_ID}}"` line. Recipes in this module already run
from the repo root (mod.just's `set working-directory := '../..'`, and the existing
`sandbox_mount/host/run_record.py` relative call proves it), so relative paths work.

Parse the active roster's `app:` block with the SAME awk parse fill.just uses
(copy the idioms verbatim, including the `ROSTER` resolution):

```bash
# ── arming preflight: an unarmed kernel must fail HERE, in seconds, on the
# HOST — not after full VM creation cost at provision step 5/9. Same roster
# parse FILL uses (the root justfile's `config` variable is not visible in a
# module, so read the same env var with the same fallback).
ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"
APP_REPO=$(awk '
  /^app:[[:space:]]*$/      { a=1; next }
  /^[^[:space:]]/           { a=0 }
  a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
' "$ROSTER")
APP_PATH=$(awk '
  /^app:[[:space:]]*$/      { a=1; next }
  /^[^[:space:]]/           { a=0 }
  a && /^[[:space:]]+path:[[:space:]]/ { print $2; exit }
' "$ROSTER")
# TARGET mode (app.repo set): no local pre-check — the repo is external and
# fill's post-clone state owns it. VENDORED mode: app.path must exist as a
# directory in THIS repo; empty path falls back to provision.sh's own default.
if [ -z "$APP_REPO" ]; then
    APP_PATH="${APP_PATH:-apps/inkwell}"
    if [ ! -d "$APP_PATH" ]; then
        echo "[mount] app.path '$APP_PATH' does not exist in this repo — write $APP_PATH/sssf.app.yaml, or set app.repo: in your roster to mount an external app (README -> Arming)" >&2
        exit 1
    fi
fi
```

Placement note: this runs before `just sbx lifecycle create`, so a failed
preflight leaves NO run record and NO VM. The recipe already has
`set -euo pipefail`; the awk probes returning empty are fine (no unbound vars).

Also update the file's header comment if it claims the chain is
"create -> fill -> setup -> observe" without mention of the preflight gate —
one clause, matching the file's comment culture.

### 2. Doctor arming check — `just/sandbox/manage/mod.just`

In the `doctor` recipe, AFTER the existing five `chk` lines and BEFORE the final
`[ "$ok" -eq 0 ] && ...` verdict line, add the arming visibility check. An unarmed
kernel is a legitimate state, so this is a WARNING that never touches `ok` and
doctor still exits 0:

```bash
# Arming visibility, not a gate: an unarmed kernel is legitimate, but it must
# not be invisible. Same roster parse as mount's preflight / fill. Target mode
# (app.repo set) has nothing local to check.
ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"
APP_REPO=$(awk '/^app:[[:space:]]*$/ { a=1; next } /^[^[:space:]]/ { a=0 } a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }' "$ROSTER")
APP_PATH=$(awk '/^app:[[:space:]]*$/ { a=1; next } /^[^[:space:]]/ { a=0 } a && /^[[:space:]]+path:[[:space:]]/ { print $2; exit }' "$ROSTER")
if [ -z "$APP_REPO" ]; then
    APP_PATH="${APP_PATH:-apps/inkwell}"
    if [ ! -d "$APP_PATH" ]; then
        printf '  WARN  app.path %s missing in this repo — kernel is UNARMED: write %s/sssf.app.yaml, or set app.repo: in your roster (README -> Arming)\n' "$APP_PATH" "$APP_PATH"
    else
        printf '  ok    app.path %s present (armed)\n' "$APP_PATH"
    fi
fi
```

(The `else` ok-line is optional; keep it if it reads well in the chk column
format — WARN/FAIL/ok alignment matters here. Either way, `ok` stays untouched
and the final verdict line is unchanged.)

Note doctor runs with `set -uo pipefail` (no `-e`) and its working directory is
`../../..` (repo root) — the relative `[ -d ]` check is correct there.

### 3. Provision backstop comment — `sandbox_mount/guest/provision.sh`

In step 5/9 ("app"), the flow today is:

```
if [[ ! -d "$APP_DIR" ]]; then ... exit 1      # dir-missing hard exit
if [[ "$APP_MANIFEST_PRESENT" == 1 ]]; then    # manifest-driven install/build
elif [[ -f "$APP_DIR/package.json" ]]; then    # package.json fallback: bun install
else  say "skipped $APP_PATH (no manifest, no package.json)"   # graceful skip
fi
```

VERIFY (read-only confirmation, no behavior change expected): an ABSENT manifest
with the app dir PRESENT already skips gracefully — `APP_MANIFEST_PRESENT=0`
prints `manifest ... absent — package.json fallback`, and with no package.json
the else branch says `skipped`. This matches the phase-1 spec. If that reading is
wrong, fix the skip; otherwise change nothing in the logic.

The dir-missing hard exit STAYS as a defensive backstop, but is now unreachable
in normal flow because the mount preflight owns that error. Add a comment on the
`if [[ ! -d "$APP_DIR" ]]` block saying exactly that, e.g.:

```bash
# Defensive backstop, now unreachable in normal flow: mount's HOST-SIDE arming
# preflight (just/sandbox/mount.just) fails in seconds on a missing vendored
# app.path long before any VM exists. This exit only fires for out-of-band
# invocation (someone piping provision.sh to a VM directly, or a hand-shipped
# roster that diverged from the host's).
```

## Verification (all three for real)

(a) **Unarmed kernel fails fast on the host.** With the default roster and no
`apps/` dir:
- Note current run count: `sandbox_mount/host/run_record.py list` (or
  `uv run sandbox_mount/host/run_record.py list` — the script is stdlib-only).
- Run `just sbx mount preflight-test-1` — must fail WITHIN SECONDS, on the host,
  with the named arming error (`[mount] app.path 'apps/your-app' does not exist
  in this repo — ...`), exit non-zero.
- Confirm NO VM was created and NO run record: `run_record.py list` shows no new
  run (`preflight-test-1` absent), and the error appears before any create output.

(b) **Doctor warns, exits 0.** `just sbx manage doctor` prints the `WARN` arming
line naming `apps/your-app` and the `README -> Arming` pointer, and exits 0
(final line still `sbx doctor: OK` assuming the other chks pass).

(c) **Armed regression — full mount.** A fresh
`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx mount <fresh-id>`
must still pass gates A–E end-to-end (target mode: `app.repo` set → preflight
skips the local check, so the armed path is untouched). This costs a real VM —
it is required. Tear down afterwards with `just sbx lifecycle teardown <id>`.

## Done means

(a), (b), (c) all demonstrated for real. Changes landed in the three files above
only. README is OUT OF SCOPE (its Arming section already documents arming; the
messages only point at it). No git ref mutations — `git add` only, tree left
dirty; the chain's commit phase owns the commit.

## Constraints / gotchas

- Modules inherit nothing from the root justfile: resolve the roster as
  `ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"` in each recipe,
  exactly as fill.just does. Do NOT try to read the root's `config` variable.
- Copy the awk parse from fill.just verbatim — the roster's `app:` block is flat
  and that parser is the established idiom for it.
- Empty `app.path` in vendored mode falls back to `apps/inkwell` (provision.sh's
  own default in its probe) so host and guest agree on what is being checked.
- Target mode (`app.repo` set) gets NO local pre-check in either mount or doctor.
- Error/warning text must name the knob (`app.path`, `sssf.app.yaml`, `app.repo:`)
  and point at `README -> Arming`. Never print secrets — none are involved here.
