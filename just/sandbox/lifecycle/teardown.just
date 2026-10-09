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
# available in this file. Step 2.5 sits between harvest and destroy: an issue
# still open at that point means the run was cancelled, and closing it needs both
# the pulled bundle (for the commits section) and a live VM (for the trace).
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
    # State-root-aware: <local_path>/sssf/runs for app runs, legacy .sandbox/runs
    # for vendored/kernel-self. run_record owns the rule; recipes never hardcode.
    RUNS="$("$RR" runs-dir)"
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
    # SSSF_CONFIG is REQUIRED and is resolved BEFORE the run-record check, so an
    # unarmed kernel fails with THE named error ("SSSF_CONFIG is not set …"), not
    # with "no run record". The app: block below picks the artifact set from it.
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
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

    # Which payload the run used: the roster's app block (same awk as FILL), from
    # the roster resolved (and required) at the top of this recipe. In
    # target mode the manifest of the target clone is added to the tar set below;
    # the target's CODE returns via the harvest bundle, but the manifest records
    # exactly what the box ran, so it comes along with the factory-root state.
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
    # The trace db path is roster data. The tar is relative to the factory root
    # on the VM (where the in-VM chain keeps kernel locations), so the artifact
    # lands at <host runs dir>/<id>-artifacts/<DB_REL> — where <host runs dir> is
    # the state root's runs/ — which _artifact_db() in issue_tracker.py mirrors.
    DB_REL=$(awk '
      /^observability:[[:space:]]*$/ { o=1; next }
      /^[^[:space:]]/                { o=0 }
      o && /^[[:space:]]+db:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    DB_REL=${DB_REL:-adws/adw_data/sssf.db}
    TAR_PATHS="specs app_docs $DB_REL run.log"
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
    # WHY a DELTA tar instead of the whole tree: the previous command here
    # (`tar cf - $TAR_PATHS`, uncompressed) shipped EVERY byte of specs/ and
    # app_docs/ — MEASURED 9.95MB on a real box whose run changed nothing in the
    # factory tree. Over that box's dal-region link (~16KB/s) that is ~10 minutes
    # of teardown spent transferring bytes the host ALREADY owns: it cloned the
    # same sha and mount gate A asserts the factory tree was clean before the run,
    # so every tracked-and-unmodified byte is reconstructible here by construction.
    # The only unique bytes are the run-delta under the tar paths (untracked
    # non-ignored + HEAD-modified files — MEASURED ZERO files on that box) plus the
    # gitignored always-files git cannot report (sssf.db, traced to 56KB, run.log,
    # target manifest). Send just those, gzip the tiny payload, and skip the
    # transfer entirely when the delta is empty.
    if [ "$VM_ALIVE" = 1 ]; then
        mkdir -p "$ART"
        TAR_TMP=$(mktemp "${TMPDIR:-/tmp}/sbx-$RUN_ID.XXXXXX")
        # One round trip. $TAR_PATHS expands on the HOST and is passed as argv;
        # ssh does not pass argv (it joins args into one string the remote login
        # shell re-parses), so the space-separated list arrives as MANY positional
        # args and is rejoined with "$*" — $1 alone would silently be just "specs".
        # Everything else stays literal on the VM (heredoc — no quote gymnastics).
        # `--diff-filter=d` drops DELETED files: they have no bytes to ship and
        # would make `tar -T` fail on a name that does not exist. Iterating the tar
        # paths with `[ -f ]` picks up the gitignored always-files and skips the
        # two directories. An empty list prints the sentinel to STDERR (stdout is
        # the tar stream) and exits 0 with empty stdout; the host then skips the
        # transfer but the artifacts dir stays created. git in a weird state (no
        # HEAD, corrupt index) degrades to the always-files rather than failing.
        ssh "${SSH_OPTS[@]}" "$VM".exe.xyz bash -s -- "$TAR_PATHS" <<'REMOTE' \
            > "$TAR_TMP" || true
        set -uo pipefail
        paths="$*"; cd app 2> /dev/null || exit 0
        list=$(mktemp)
        { git ls-files --others --exclude-standard -- $paths 2> /dev/null
          git diff --name-only --diff-filter=d HEAD -- $paths 2> /dev/null; } >> "$list"
        for f in $paths; do [ -f "$f" ] && echo "$f" >> "$list"; done
        sort -u -o "$list" "$list"
        if [ -s "$list" ]; then
            tar czf - -T "$list"
        else
            echo "no run artifacts to pull — factory tree unchanged" >&2
        fi
        rm -f "$list"
    REMOTE
        if [ -s "$TAR_TMP" ]; then
            tar xzf "$TAR_TMP" -C "$ART"
            echo "   artifacts -> $ART"
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

    # ── 2.5 issue tracking: a still-open issue means the run was cancelled ───
    # Where step 2 is "bring the work home", this is "record that the run was cut
    # short". `close` is idempotent (already-closed -> warn, exit 0), so the normal
    # watcher-beat-teardown case costs one gh call and no churn. Best-effort: a
    # failure here only prints the reconciliation command. SSSF_ISSUES=0 skips.
    if [ "${SSSF_ISSUES:-1}" != "0" ]; then
        ISSUE_NUM=$("$RR" get "$RUN_ID" issue_number 2>/dev/null || true)
        if [ -n "$ISSUE_NUM" ]; then
            HARVEST_NOTE=skipped
            if [ "$HARVEST" = 1 ] && [ "$VM_ALIVE" = 1 ]; then HARVEST_NOTE=ran; fi
            uv run sandbox_mount/host/issue_tracker.py close "$RUN_ID" --outcome cancelled \
                --note "closed at teardown $(date -u +%Y-%m-%dT%H:%M:%SZ); VM ${VM:-gone}; harvest $HARVEST_NOTE" \
                || echo "   issues: close-at-teardown failed (best-effort) — run 'just sbx manage sync-issues'"
        fi
    else
        echo "   issues: disabled (SSSF_ISSUES=0)"
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
