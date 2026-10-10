# Plan: `just local close` — the finish verb for local-mode runs

## Context

Local-mode runs (`just local mount` / `execute`) write a run record with
`vm_name=local`, but there is no teardown and no finish verb — records
accumulate with `closed_at` null forever. The sandbox lane closes records via
`run_record.py close` from `just/sandbox/lifecycle/teardown.just`; the local
lane needs its own explicit closer.

Key facts already verified in the repo:

- `sandbox_mount/host/run_record.py` is stdlib-only and has everything needed:
  `get <id> [field]` (exit 1 + `run_record: no run record: ...` on unknown id),
  `close <id>` (sets `closed_at` to UTC `%Y-%m-%dT%H:%M:%SZ` via its `_now()` —
  the exact format teardown gets, and idempotent: first close wins),
  `list` (JSON array of all records, merging the resolved state root AND the
  legacy `.sandbox/runs/` fallback), `state-root` (prints e.g.
  `<local_path>/sssf`).
- `sandbox_mount/host/require_sssf_config.sh` is the shared SSSF_CONFIG guard —
  prints THE named error and exits 1 when unset. Used by every other local
  recipe.
- The roster `app.local_path` awk idiom is already duplicated in `mount`,
  `execute`, and `doctor` in `just/local.just` — reuse it verbatim.
- Record fields available for the summary: `tag`, `base_ref`, `issue_url`
  (all nullable), plus `vm_name`, `closed_at`.
- `just/local.just` has `set working-directory := '..'`, `set
  positional-arguments`, `set dotenv-load` — recipes run from the repo root.

## Files to touch

1. `just/local.just` — add ONE new recipe `close` (place it after `execute`,
   before `ui`).
2. `README.md` — one sentence in the `## Local development — \`just local\``
   section.

Nothing else. No changes to `run_record.py` (its `close`/`list` verbs already
do exactly what is needed).

## Change 1: `close` recipe in `just/local.just`

```just
# close local run records — the local lane's finish verb. There is no VM to
# tear down, so this is ALL that "ending" a local run means: stamp closed_at
# (UTC, same format teardown writes) and print a finish summary. NEVER deletes
# the run branch and NEVER touches non-local (VM) records.
#   just local close <run-id>   close one record (idempotent)
#   just local close --all      close EVERY open local record (vm_name == 'local', closed_at empty)
close RUN_ID:
    #!/usr/bin/env bash
    set -euo pipefail
    RR="sandbox_mount/host/run_record.py"
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
    export SSSF_CONFIG="$ROSTER"

    if [ "{{RUN_ID}}" = "--all" ]; then
        # Bulk-close every OPEN local record. `list` merges the state root AND
        # legacy .sandbox/runs, so legacy local records are closed too (written
        # in place by run_record). VM records (vm_name != 'local') are skipped.
        mapfile -t IDS < <("$RR" list | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("vm_name") == "local" and not r.get("closed_at"):
        print(r["run_id"])
')
        if [ "${#IDS[@]}" -eq 0 ]; then
            echo "no open local run records — nothing to close"
            exit 0
        fi
        for id in "${IDS[@]}"; do
            "$RR" close "$id"
            echo "closed: $id"
        done
        echo "closed ${#IDS[@]} local run record(s)"
        exit 0
    fi

    # ── single-run close ────────────────────────────────────────────────────
    if ! "$RR" get "{{RUN_ID}}" >/dev/null 2>&1; then
        echo "[local close] no run record for {{RUN_ID}} — nothing to close" >&2
        exit 1
    fi
    CLOSED=$("$RR" get "{{RUN_ID}}" closed_at)
    if [ -n "$CLOSED" ]; then
        echo "{{RUN_ID}} already closed (closed_at=$CLOSED) — nothing to do"
        exit 0
    fi
    "$RR" close "{{RUN_ID}}"   # stamps closed_at UTC, same format teardown uses

    # ── FINISH SUMMARY (a few lines) ────────────────────────────────────────
    TAG=$("$RR" get "{{RUN_ID}}" tag)
    BASE=$("$RR" get "{{RUN_ID}}" base_ref)
    ISSUE=$("$RR" get "{{RUN_ID}}" issue_url)
    STATE=$("$RR" state-root)

    # payload clone + surviving run branch (same awk idiom as mount/execute)
    APP_LOCAL=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+local_path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    LOCAL_PATH="${APP_LOCAL/#\~/$HOME}"
    BRANCH="local/{{RUN_ID}}"
    SURVIVING=""
    if [ -n "$LOCAL_PATH" ] && git -C "$LOCAL_PATH" rev-parse --git-dir >/dev/null 2>&1; then
        SURVIVING=$(git -C "$LOCAL_PATH" branch --list "$BRANCH")
    fi

    echo ""
    echo "FINISH SUMMARY"
    echo "  run:     {{RUN_ID}}${TAG:+ (tag: $TAG)}"
    echo "  closed:  $("$RR" get "{{RUN_ID}}" closed_at)"
    if [ -n "$BASE" ]; then
        echo "  target:  base_ref $BASE"
    fi
    if [ -n "$SURVIVING" ]; then
        echo "  branch:  $BRANCH (still in $LOCAL_PATH — close does not delete branches)"
    fi
    [ -n "$ISSUE" ] && echo "  issue:   $ISSUE"
    [ -n "$STATE" ] && echo "  state:   $STATE/"
```

Implementation notes for the builder:

- Keep the summary to a handful of lines as sketched; exact wording is yours
  but it MUST cover: run id, tag, target repo+branch (base_ref if recorded;
  the run branch `local/<run-id>` when the clone exists), issue link if
  recorded, state location (`<...>/sssf/`), and the surviving-branch reminder
  via `git -C <local_path> branch --list 'local/<run-id>'`.
- Do NOT add a `vm_name == 'local'` refusal to single-run close — the prompt
  does not ask for one (unknown record errors, idempotent re-close are the
  only guards).
- `python3` is guaranteed present (run_record.py itself runs on it); do not
  use `jq`.
- Header comment for the recipe follows the file's existing comment style.

## Change 2: README

One sentence in the `## Local development — \`just local\`` section (good
spot: right after the ```sh command block, near the existing flow lines, or
beside "the one hard rule" paragraph around line 533). Content along the
lines of:

> A local session ends with `just local close <run-id>` — there is no VM
> teardown, and without it the run record stays open forever (`just local
> close --all` bulk-closes every open local record).

One sentence; do not restructure the section or touch the SSSF_CONFIG table.

## Verification (do it for real, capture output for the envelope)

Environment facts: the hello roster `adws/adw_sssf_config/sssf.hello.config.yaml`
has `local_path` COMMENTED OUT (target mode), so a scratch roster copy is
needed for the local mount. Existing records live in legacy `.sandbox/runs/`;
among them are OPEN local records (`isohello1`, `isoscratch1`, `rename-check`)
and OPEN non-local records (`verify-*` with `vm_name` set to a VM name). List
the open local records BEFORE step (d) so the count you report accounts for
every one `--all` legitimately closes — the prompt's "both remaining" assumed
two; report what is actually there.

Steps:

0. Snapshot baseline: `SSSF_CONFIG=<roster> sandbox_mount/host/run_record.py list`
   — record which local records are open and the `closed_at` of the hello-* /
   verify-* VM records.
1. Scratch roster: copy `adws/adw_sssf_config/sssf.hello.config.yaml` to
   `/tmp/sssf.hello-close-verify.config.yaml` and set `app.local_path:` to a
   clone path OUTSIDE the kernel (e.g. `/home/huang/projects/hello-close-verify`).
   (a) `SSSF_CONFIG=/tmp/... just local mount closeverify1` →
       `run_record.py get closeverify1 closed_at` prints EMPTY (record OPEN).
   (b) `just local close closeverify1` → exit 0, `closed_at` now set
       (`YYYY-MM-DDTHH:MM:SSZ`), FINISH SUMMARY printed with run id, base/branch
       line, state path, surviving-branch reminder.
   (c) `just local close closeverify1` again → exit 0, "already closed" message,
       `closed_at` UNCHANGED.
   (d) `just local mount closeverify2` (second open local record), then
       `just local close --all` → prints `closed: <id>` per open local record
       (closeverify2 plus any leftover open local records from the baseline)
       and a final count; exits 0. Re-run `close --all` → "no open local run
       records", exit 0.
   (e) Diff the VM records against the baseline: every record with
       `vm_name != 'local'` (hello-*, verify-*, canary-*, …) has the SAME
       `closed_at` as before — `--all` touched none of them.
   (f) `git -C /home/huang/projects/hello-close-verify branch --list
       'local/closeverify1'` still prints the branch — close did NOT delete it.
2. Negative checks: `just local close no-such-run` → exit 1, named error;
   `env -u SSSF_CONFIG just local close x` → the shared SSSF_CONFIG named error.
3. `just --list local` shows `close`; `git status` clean except
   `just/local.just` + `README.md`.

Cleanup after verification: the scratch clone + roster live outside the repo
(/tmp and ~/projects) — leave or remove, but nothing scratch lands in the
repo tree. Note the closed legacy records (isohello1 etc.) are a real,
intended side effect of demonstrating `--all`; mention them in the envelope.

## Out of scope

Everything else: no issue closing, no branch deletion, no changes to
run_record.py, teardown, or any other recipe/doc.
