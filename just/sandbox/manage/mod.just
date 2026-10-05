# just/sandbox/manage/mod.just — auxiliary: preflight, readback, fleet ops.
#
# Nothing here is a phase. None of it writes to the run record, and none of it
# changes anything: these are the commands you run to find out where you stand,
# before or after the lifecycle does its work.
#
# A module inherits nothing, so the settings are repeated here with one more `..`
# than the parent. dotenv-load matters in this one: `doctor` checks that every
# roster provider's key is set, reading the .env the same way FILL does.
set working-directory := '../../..'
set positional-arguments
set dotenv-load

import 'list.just'
import 'harvest.just'

# list the management commands
default:
    @just --list sbx::manage

# are the host prerequisites in place? run this before anything else
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    ok=0
    chk() { if eval "$2" >/dev/null 2>&1; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; ok=1; fi; }
    chk "ssh exe.dev reachable"            'ssh -o BatchMode=yes -o ConnectTimeout=15 exe.dev whoami'
    chk "run_record helper runs"           'sandbox_mount/host/run_record.py list'
    chk "provisioner present"              '[ -x sandbox_mount/guest/provision.sh ]'
    chk "roster provider keys set"         'sandbox_mount/host/roster_keys.sh'
    chk "adw layer resolves"               'just --list adw'

    # ── arming visibility, NOT a gate: an unarmed kernel is a legitimate state,
    # but it must not be invisible — that is exactly how the late-failure defect
    # hid. Same roster parse as mount's preflight / fill. Target mode (app.repo
    # set) has nothing local to check. Never touches `ok`, so doctor still exits 0.
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

    [ "$ok" -eq 0 ] && echo "  sbx doctor: OK" || { echo "  sbx doctor: FAILED"; exit 1; }
