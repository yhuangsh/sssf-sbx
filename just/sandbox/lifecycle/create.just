# Phase 1 — CREATE. Host only: control plane. Nothing lands on the VM.
#
# This file is IMPORTED by the root justfile, so it shares the root's scope and
# must not repeat `set dotenv-load` / `set positional-arguments` (duplicate
# settings are a parse error). Relative paths resolve against the repo root
# because an import — unlike a `mod` — keeps the root's working directory.
#
# Strict order, and the order is the whole design: record → VM → wait for ssh.
#   record first  a crash anywhere after leaves teardown a handle to work from.
# Nothing here ever destroys a VM. Failures stop and print the teardown command;
# the box stays alive so it can be inspected.

# boot a VM for one run: just sbx lifecycle create <task-or-run-id> [tag]
create RUN_ID TAG='':
    #!/usr/bin/env bash
    set -euo pipefail

    RR="sandbox_mount/host/run_record.py"

    # Preflight before anything is created, so a missing dependency cannot leave
    # a half-built run behind.
    for bin in ssh python3; do
        command -v "$bin" >/dev/null || { echo "create: '$bin' not on PATH" >&2; exit 1; }
    done

    # SSSF_CONFIG is REQUIRED and is resolved BEFORE the run record exists: an
    # unarmed kernel must leave no orphan record behind. Shared guard -> THE named
    # error. $ROSTER is reused for the tag derivation in 2b below.
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)

    # ── 1. run id ──────────────────────────────────────────────────────────────
    # The run id becomes the VM name and the VM name becomes a public hostname,
    # so a collision is two runs fighting over one URL. Anything without the
    # -<6 hex> suffix gets run through new-id, which adds the date + entropy.
    RUN_ID="{{RUN_ID}}"
    if [[ ! "$RUN_ID" =~ -[0-9a-f]{6}$ ]]; then
        RUN_ID="$("$RR" new-id "$RUN_ID")"
    fi
    # Hostname-safe or DNS will not carry it.
    if ! [[ "$RUN_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || [ ${#RUN_ID} -gt 63 ]; then
        echo "create: run id '$RUN_ID' is not a valid hostname label" >&2; exit 1
    fi
    echo "run id:  $RUN_ID"   # later phases all take this id — it is the handle

    # ── 2. run record (before the VM: teardown always has something to find) ───
    RECORD="$("$RR" create "$RUN_ID")"
    echo "record:  $RECORD"

    # From here on a failure leaves real resources. Never destroy anything —
    # report, stop, and say how to clean up.
    _on_exit() {
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '\ncreate FAILED (exit %s). Nothing was destroyed — inspect, then:\n  just sbx lifecycle teardown %s\n' "$rc" "$RUN_ID" >&2
        fi
        exit "$rc"
    }
    trap _on_exit EXIT

    # ── 2b. the tag ────────────────────────────────────────────────────────────
    # Bulk identification/cleanup filters on this, so it names the APP, not the
    # kernel's ancestor. Explicit arg wins; else derive from the ACTIVE roster's
    # app.repo basename; vendored (no repo:) -> "sssf". Same required $ROSTER and
    # same app: block awk as mount/fill/teardown (resolved in preflight above).
    TAG="{{TAG}}"
    if [ -z "$TAG" ] && [ -f "$ROSTER" ]; then
        APP_REPO=$(awk '
          /^app:[[:space:]]*$/      { a=1; next }
          /^[^[:space:]]/           { a=0 }
          a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
        ' "$ROSTER" 2>/dev/null || true)
        if [ -n "$APP_REPO" ]; then
            base="${APP_REPO##*/}"; base="${base%.git}"   # .../hello-server.git -> hello-server
            TAG="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' \
                   | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')"
            TAG="${TAG:0:32}"; TAG="${TAG%-}"             # cap, then re-trim a cut dash
        fi
    fi
    [ -n "$TAG" ] || TAG=sssf
    "$RR" set "$RUN_ID" tag="$TAG"
    echo "tag:     $TAG"

    # ── 3. the VM ──────────────────────────────────────────────────────────────
    # Control plane is plain ssh; --json makes it scriptable. --tag is what bulk
    # cleanup filters on — the APP this run mounts, resolved above.
    echo "vm:      creating $RUN_ID (tag $TAG) ..."
    VM_JSON="$(ssh exe.dev new --name "$RUN_ID" --tag "$TAG" --json)"

    # The exact key names of `new --json` are UNVERIFIED (only `ls --json` was
    # observed: {"vms":[{vm_name,https_url,ssh_dest,...}]}). Accept the shapes we
    # have seen and the obvious variants rather than guessing one.
    PARSED="$(printf '%s' "$VM_JSON" | python3 -c '
    import json, sys
    try:
        d = json.loads(sys.stdin.read())
    except ValueError:
        d = {}
    if isinstance(d, dict) and isinstance(d.get("vm"), dict):
        d = d["vm"]
    if isinstance(d, dict) and isinstance(d.get("vms"), list) and d["vms"]:
        d = d["vms"][0]
    if not isinstance(d, dict):
        d = {}
    print(d.get("vm_name") or d.get("name") or "")
    print(d.get("https_url") or d.get("url") or "")
    ')"
    { read -r VM_NAME || true; read -r HTTPS_URL || true; } <<< "$PARSED"

    # Fallback on an unrecognised payload: ask the one shape that IS verified.
    if [ -z "${VM_NAME:-}" ]; then
        echo "vm:      'new --json' shape unrecognised, re-reading from 'ls --json'"
        PARSED="$(ssh exe.dev ls "$RUN_ID" --json | python3 -c '
    import json, sys
    want = sys.argv[1]
    vms = (json.load(sys.stdin) or {}).get("vms") or []
    hit = next((v for v in vms if v.get("vm_name") == want), None) or {}
    print(hit.get("vm_name") or "")
    print(hit.get("https_url") or "")
    ' "$RUN_ID")"
        { read -r VM_NAME || true; read -r HTTPS_URL || true; } <<< "$PARSED"
    fi
    [ -n "${VM_NAME:-}" ] || { echo "create: could not determine the VM name for $RUN_ID" >&2; exit 1; }
    # Measured: --name becomes the public hostname, so this derivation is safe.
    [ -n "${HTTPS_URL:-}" ] || HTTPS_URL="https://${VM_NAME}.exe.xyz"

    "$RR" set "$RUN_ID" vm_name="$VM_NAME" https_url="$HTTPS_URL"

    # ── 3b. did the tag land? ──────────────────────────────────────────────────
    # `new --json`'s key names are UNVERIFIED; `ls --json` demonstrably carries
    # "tags". Trust the create payload when it names the tag, otherwise re-read the
    # one shape that is verified. A missing tag is FATAL: the tag's only job is bulk
    # cleanup, and a silent miss is a VM no cleanup pass will ever find.
    TAGS="$(printf '%s' "$VM_JSON" | python3 -c '
    import json, sys
    try:
        d = json.loads(sys.stdin.read())
    except ValueError:
        d = {}
    if isinstance(d, dict) and isinstance(d.get("vm"), dict):
        d = d["vm"]
    if isinstance(d, dict) and isinstance(d.get("vms"), list) and d["vms"]:
        d = d["vms"][0]
    if not isinstance(d, dict):
        d = {}
    print(" ".join(d.get("tags") or []))
    ')"
    if ! printf ' %s ' "$TAGS" | grep -qF " $TAG "; then
        TAGS="$(ssh exe.dev ls "$VM_NAME" --json | python3 -c '
    import json, sys
    want = sys.argv[1]
    vms = (json.load(sys.stdin) or {}).get("vms") or []
    hit = next((v for v in vms if v.get("vm_name") == want), {})
    print(" ".join(hit.get("tags") or []))
    ' "$VM_NAME")"
    fi
    case " $TAGS " in
        *" $TAG "*) echo "tag:     $TAG confirmed on $VM_NAME (tags: $TAGS)" ;;
        *) echo "create: tag '$TAG' did not land on $VM_NAME (reported: ${TAGS:-<none>})" >&2; exit 1 ;;
    esac

    echo "vm:      $VM_NAME  ->  $HTTPS_URL  (tag $TAG)"

    # ── 4. wait for ssh ────────────────────────────────────────────────────────
    # All *.exe.xyz share one host key and the wildcard known_hosts entry is
    # already installed, so BatchMode never stalls on a prompt.
    echo "ssh:     waiting for $VM_NAME.exe.xyz (up to 60s) ..."
    WAIT_START=$SECONDS
    DEADLINE=$((SECONDS + 60))
    READY=0
    while [ "$SECONDS" -lt "$DEADLINE" ]; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM_NAME.exe.xyz" true >/dev/null 2>&1; then
            READY=1; break
        fi
        sleep 2
    done
    if [ "$READY" -ne 1 ]; then
        echo "create: ssh never answered on $VM_NAME.exe.xyz within 60s" >&2
        exit 1
    fi
    echo "ssh:     up after $((SECONDS - WAIT_START))s"

    # ── 5. session id ──────────────────────────────────────────────────────────
    # pi's `--session-id` CREATES the session if missing and CONTINUES it when it
    # exists, so one id drives every turn of the `just sbx run agent` lane. It is
    # minted once, here, and lives in the record.
    SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    "$RR" set "$RUN_ID" session_id="$SESSION_ID"
    echo "session: $SESSION_ID"

    echo
    echo "created  $RUN_ID  (no code on the box yet)"
    echo "next     just sbx lifecycle fill $RUN_ID"
