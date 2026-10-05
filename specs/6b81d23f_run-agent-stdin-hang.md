# Plan: Fix run-agent hang — redirect stdin from /dev/null in `just/sandbox/run/mod.just`

## Problem

Both ssh invocations in `just/sandbox/run/mod.just` leave stdin attached to the
host terminal. Run from an interactive TTY, ssh binds the local TTY to the
remote command's stdin:

- `agent` recipe (~line 68, the line ending `pi -p --session-id $SID $Q`):
  `pi -p` never reads stdin and never receives EOF, so pi finishes its turn but
  the ssh session never returns — the command appears hung until ctrl-C
  (exit 255).
- `cmd` recipe (~line 42): the same latent hang for any remote command that
  reads stdin.

Reproduced (per task): from a closed-stdin shell the exact command pongs and
exits in 1.5s; from an interactive TTY it hangs after the pricing-warning line.

## Fix

File: `just/sandbox/run/mod.just` — the ONLY file to modify.

1. **`cmd` recipe ssh line** (currently):
   ```
   ssh "$VM".exe.xyz "cd app && {{CMD}}"
   ```
   becomes:
   ```
   ssh "$VM".exe.xyz "cd app && {{CMD}}" < /dev/null
   ```

2. **`agent` recipe ssh line** (currently):
   ```
   ssh "$VM".exe.xyz "cd app && if [ -f .env ]; then set -a; . ./.env; set +a; fi; pi -p --session-id $SID $Q"
   ```
   becomes:
   ```
   ssh "$VM".exe.xyz "cd app && if [ -f .env ]; then set -a; . ./.env; set +a; fi; pi -p --session-id $SID $Q" < /dev/null
   ```

   The `< /dev/null` goes on the ssh invocation itself (outside the quoted
   remote command), so the REMOTE pi sees immediate EOF while stdout keeps
   streaming to the local terminal — the lane stays synchronous by design.

3. **Extend the recipe comments** — add ONE line near each changed invocation
   noting WHY stdin is redirected. Suggested wording (one line, fits the
   existing comment style):

   > `# < /dev/null: pi -p ignores stdin but needs EOF to exit; an interactive host TTY otherwise pins the ssh session open after the turn completes.`

   For the `cmd` recipe, the same idea phrased generically (any command that
   reads stdin would hang the same way). Keep it to one line each; do not
   restructure the existing comments.

Keep EVERYTHING else identical — no changes to recipes, quoting, error paths,
or other modules.

## Verify

(a) Parse checks (must pass):
```
bash -n just/sandbox/run/mod.just
just --list sbx::run
```
Judge by exit status only.

(b) Live behavioral proof — needs a mounted VM. Check first:
```
python3 sandbox_mount/host/run_record.py get hello-20261005-6c1cdf vm_name
```
(As of planning time this returns "no run record" — re-check at build time.)

- If a live vm_name exists, run the EXACT hang shape, time-boxed:
  ```
  timeout 120 just sbx run agent hello-20261005-6c1cdf "reply with pong"
  ```
  Confirm it RETURNS: pong printed, exit 0 (NOT a hang, NOT exit 124/255).
- If no live VM exists, verify (a) only and honestly blocked-report leg (b) —
  do not fabricate the live result.

## Commit lane

Do NOT self-commit. The chain's commit phase owns the commit. Leave the tree
with the change dirty; report `just/sandbox/run/mod.just` in changed_files.

## Done means

- `< /dev/null` added to both ssh invocations, comment lines extended.
- (a) green.
- (b) live-leg green, or honestly blocked-reported if no live VM.
- Nothing else touched.

## Out of scope

Everything else.
