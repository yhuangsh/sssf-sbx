# Phase 6 — TEARDOWN. Host only, and only when we decide.
#
# IMPORTED into the root justfile (not a module): no `set` lines here. No
# file-level variables either — six imports share one scope, so a duplicate
# name across phase files is a hard error. Everything is a bash local instead.
#
# Order is load-bearing: everything that READS the box runs before the one thing
# that destroys it. Artifacts come out, commits are harvested, then the VM is
# destroyed and the record closed. The harvest failing ABORTS the whole teardown:
# destroying a VM whose commits were never pulled is the one irreversible mistake
# available in this file.
#
# Per-run cost is NOT captured here. It comes from pi's own accounting in the
# trace db (`just obs sessions` shows `total_cost`), and setup gate D already
# proves the rate table is loaded.
#
# IDEMPOTENT by construction: every step is individually guarded, because a run
# can die anywhere — VM but no record, record but no VM, one whose VM is already
# gone. A missing piece is the normal path, not an error.

# tear down one run: artifacts -> harvest -> destroy -> close
teardown RUN_ID *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"

    RR="sandbox_mount/host/run_record.py"
    RUN_ID="{{ RUN_ID }}"
    RUNS=".sandbox/runs"
    ART="$RUNS/$RUN_ID-artifacts"

    # Through a variable, not straight into `for ... in`: interpolating an empty
    # variadic into the list is a syntax error, via a variable it is zero iterations.
    RAW_FLAGS="{{ FLAGS }}"
    HARVEST=1
    for a in $RAW_FLAGS; do
        case "$a" in
            --no-harvest) HARVEST=0 ;;
            *) echo "teardown: unknown flag $a (only --no-harvest)"; exit 2 ;;
        esac
    done
    # All *.exe.xyz share one host key and a wildcard known_hosts entry is already
    # installed, so no StrictHostKeyChecking games. BatchMode so a teardown never
    # sits at a password prompt; timeouts so it never hangs on a dead VM.
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

    echo "── teardown $RUN_ID"

    # The record is the only handle on the run. Without it there is nothing to
    # close, so this is the one hard prerequisite.
    "$RR" get "$RUN_ID" > /dev/null || { echo "!! no run record for $RUN_ID — nothing to tear down"; exit 1; }
    VM=$("$RR" get "$RUN_ID" vm_name)
    CLOSED=$("$RR" get "$RUN_ID" closed_at)
    [ -n "$CLOSED" ] && echo "   (record already closed at $CLOSED — re-running the remaining steps)"

    # Which payload the run used: the roster's app block (same awk as FILL). In
    # target mode the manifest of the target clone is added to the tar set below;
    # the target's CODE returns via the harvest bundle, but the manifest records
    # exactly what the box ran, so it comes along with the factory-root state.
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
    APP_MANIFEST=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+manifest:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    [ -n "$APP_MANIFEST" ] || APP_MANIFEST=sssf.app.yaml
    TAR_PATHS="specs app_docs adws/adw_data/sssf.db run.log"
    if [ -n "$APP_REPO" ]; then
        [ -n "$APP_PATH" ] || APP_PATH=target
        TAR_PATHS="$TAR_PATHS $APP_PATH/$APP_MANIFEST"
    fi

    # ── does the VM still exist? -------------------------------------------------
    # Ask the control plane rather than probing ssh: authoritative, and the same
    # answer fleet cleanup uses. Verified shape: {"vms":[{"vm_name":"...",...}]}
    VM_ALIVE=0
    if [ -n "$VM" ]; then
        VM_LIST=$(ssh "${SSH_OPTS[@]}" exe.dev ls --json 2>/dev/null || echo '{"vms":[]}')
        if printf '%s' "$VM_LIST" | VM="$VM" python3 -c \
            'import json,os,sys; sys.exit(0 if os.environ["VM"] in {v.get("vm_name") for v in json.load(sys.stdin).get("vms",[])} else 1)'
        then
            VM_ALIVE=1
        fi
    fi
    if [ "$VM_ALIVE" = 1 ]; then echo "   vm:  $VM (running)"; else echo "   vm:  ${VM:-<none>} (gone or never created)"; fi

    # ── 1. artifacts ------------------------------------------------------------
    if [ "$VM_ALIVE" = 1 ]; then
        mkdir -p "$ART"
        TAR_TMP=$(mktemp "${TMPDIR:-/tmp}/sbx-$RUN_ID.XXXXXX")
        # One round trip, and `ls -d` filters to what actually exists so a run that
        # died before writing app_docs/ (or before the target clone) is not an error.
        ssh "${SSH_OPTS[@]}" "$VM".exe.xyz \
            "cd app 2>/dev/null || exit 0; P=\$(ls -d $TAR_PATHS 2>/dev/null); [ -z \"\$P\" ] && exit 0; tar cf - \$P" \
            > "$TAR_TMP" || true
        if [ -s "$TAR_TMP" ]; then
            tar xf "$TAR_TMP" -C "$ART"
            echo "   artifacts -> $ART"
        else
            echo "   artifacts: none found on the vm"
            rmdir "$ART" 2> /dev/null || true   # do not leave an empty dir implying we pulled something
        fi
        rm -f "$TAR_TMP"
    else
        echo "   artifacts: skipped (no vm)"
    fi

    # ── 2. harvest the commits --------------------------------------------------
    # File copies LOSE history, and SSSF commits plan, code and docs as separate
    # commits — the shape of the run is in the commit graph, not the files. The
    # bundling lives in harvest.just so it can also be run on its own, at any time,
    # without committing to a teardown. Default ON here so nobody loses a run's work
    # by forgetting; a failure STOPS before destroy.
    if [ "$HARVEST" != 1 ]; then
        echo "   harvest: skipped (--no-harvest)"
    elif [ "$VM_ALIVE" = 1 ]; then
        just sbx manage harvest "$RUN_ID" || {
            echo "!! harvest FAILED — stopping before destroy. The VM is left alive."
            echo "!! diagnose, then re-run:      just sbx lifecycle teardown $RUN_ID"
            echo "!! or skip it deliberately:    just sbx lifecycle teardown $RUN_ID --no-harvest"
            exit 1
        }
    else
        echo "   harvest: skipped (no vm)"
    fi

    # ── 3. destroy the vm -------------------------------------------------------
    if [ "$VM_ALIVE" = 1 ]; then
        ssh "${SSH_OPTS[@]}" exe.dev rm "$VM" > /dev/null
        echo "   vm: destroyed ($VM)"
    else
        echo "   vm: nothing to destroy"
    fi

    # ── 4. close the record -----------------------------------------------------
    "$RR" close "$RUN_ID"
    echo "   record closed"
    echo "✓ teardown complete for $RUN_ID"
