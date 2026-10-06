# just/sandbox/mount.just — the phase chain.
#
# Lives here rather than inline in the root justfile so the whole `sbx` surface
# sits in one directory, split from the in-sandbox `adw` layer by which
# credential it needs.
#
# Imported by the root justfile, so no `set` lines here.

# arming preflight -> create -> fill -> setup -> observe. Stops at observe by
# design: teardown is ALWAYS an explicit separate decision, never chained. The
# preflight gates the chain on the host: a mis-armed roster fails in seconds,
# before any VM exists, instead of at provision step 5/9 inside the VM.
# Optional second arg = the VM tag; empty derives the app name in create.
mount RUN_ID TAG='':
    #!/usr/bin/env bash
    set -euo pipefail

    # ── arming preflight: an unarmed kernel must fail HERE, in seconds, on the
    # HOST — not after full VM creation cost at provision step 5/9. Same roster
    # parse FILL uses; SSSF_CONFIG is REQUIRED and the shared guard prints THE
    # named error and exits before anything is created (no silent fallback).
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
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

    just sbx lifecycle create "{{RUN_ID}}" "{{TAG}}"
    ID=$(sandbox_mount/host/run_record.py list | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["run_id"])')
    just sbx lifecycle fill    "$ID"
    just sbx lifecycle setup   "$ID"
    just sbx lifecycle observe "$ID"
    printf '\nmounted: %s\n  execute: just sbx lifecycle execute %s "<prompt>"\n  agent:   just sbx run agent %s "<prompt>"\n  harvest: just sbx manage harvest %s\n  destroy: just sbx lifecycle teardown %s\n' "$ID" "$ID" "$ID" "$ID" "$ID"

