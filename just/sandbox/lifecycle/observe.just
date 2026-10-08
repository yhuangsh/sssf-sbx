# ─── just/sandbox/observe.just — PHASE 5 · OBSERVE ────────────────────────────
# Make a mounted sandbox watchable from outside without reaching in: start the
# app (the roster's app.path, on the manifest's serve.port, default 4501) and the
# trace UI (4600), retarget the HTTPS proxy, print URLs. A manifest with no
# serve: block is a library/CLI app — the app lane is skipped, not failed.
#
# IMPORTED by the root justfile, not a module: no `set` lines here (the root
# already owns `set dotenv-load` / `set positional-arguments`, and a duplicate
# setting is a hard error), and the root's variable scope is shared.
#
# HOST-ONLY in practice: this phase touches the exe.dev control plane, which a
# sandbox has no credential for. It needs NO secrets at all.
#
# NEVER destroys the VM. Every failure below reports and exits non-zero with the
# box still up, because the evidence you need lives on it. `just sbx lifecycle teardown` stays
# an explicit, separate decision.

# Phase 5 · start both servers if down, expose the app port anonymously, print the URLs
observe RUN_ID:
    #!/usr/bin/env bash
    set -euo pipefail

    RR="sandbox_mount/host/run_record.py"

    # The run record is the ONLY state shared across the six phases; nothing
    # else survives between them.
    VM=$("$RR" get {{RUN_ID}} vm_name)
    if [ -z "$VM" ]; then
        echo "observe: run record {{RUN_ID}} has no vm_name — run 'just sbx lifecycle create' first" >&2
        exit 1
    fi
    HOST="$VM.exe.xyz"

    APP_PORT=4501
    OBS_PORT=4600
    # The factory clone is `app` relative to the exedev user's home, so this is
    # /home/exedev/app on a stock exeuntu VM. The app dir itself comes from the
    # roster's app.path (below); this visualizer path is factory machinery.
    # OBS_DB is resolved from the roster's observability.db right after the probe
    # below (a namespaced hello roster traces into local/hello/sssf.db).
    OBS_DIR='$HOME/app/.claude/skills/sssf/apps/visualizer'

    echo "── observe {{RUN_ID}} · vm $VM ──────────────────────────────"

    # ── 0. reachability ──────────────────────────────────────────────────────
    # Proven up front so that every `ss` probe below can read a non-zero exit as
    # "not listening" rather than "ssh is broken". All *.exe.xyz share one host
    # key and a wildcard known_hosts entry is already installed, so this is
    # non-interactive.
    if ! ssh "$HOST" 'true' >/dev/null 2>&1; then
        echo "observe: cannot ssh $HOST — VM left up for debugging" >&2
        exit 1
    fi
    echo "[1/6] ssh ok — $HOST"

    # `ss -ltn` column 4 is Local Address:Port. bun binds 0.0.0.0 by default so
    # a live server shows as *:4501, which the :PORT suffix match catches. The
    # proxy cannot reach a 127.0.0.1 bind, so this doubles as a bind check.
    listening() {
        ssh "$HOST" 'ss -ltn' 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
    }

    # Poll rather than sleep-a-guess: bun is up in well under a second warm, but
    # a cold first read of dist/ is slower.
    wait_listen() {
        local port="$1" tries=0
        until listening "$port"; do
            tries=$((tries + 1))
            [ "$tries" -ge 20 ] && return 1
            sleep 1
        done
        return 0
    }

    # ── the app lane is DATA: the roster names app.path, the app's own manifest
    # names its serve: block. ONE parser, the uv PEP-723 probe provision.sh
    # established (pyyaml), its own resolve noise on stderr and stdout exactly
    # the shlex-quoted assignments. awk stays reserved for the roster's flat
    # blocks; do not add a second YAML parser style.
    APP_ENV=$(ssh "$HOST" 'uv run -' <<'PROBE'
    # /// script
    # dependencies = ["pyyaml"]
    # ///
    """Resolve app.path/app.manifest + the manifest's serve: block into shell vars."""

    import shlex
    from pathlib import Path

    import yaml

    try:
        cfg = yaml.safe_load(Path("/home/exedev/sssf_config.yaml").read_text()) or {}
    except FileNotFoundError:
        cfg = {}
    app = cfg.get("app") or {}
    path = app.get("path") or "apps/inkwell"
    manifest = app.get("manifest") or "sssf.app.yaml"
    manifest_path = Path.home() / "app" / path / manifest
    present = manifest_path.is_file()
    data = (yaml.safe_load(manifest_path.read_text()) or {}) if present else {}
    serve = data.get("serve") or {}
    if not isinstance(serve, dict):
        serve = {}

    def emit(key, value):
        print(f"{key}={shlex.quote(str(value))}")

    emit("APP_PATH", path)
    emit("APP_MANIFEST", manifest)
    emit("SERVE_PRESENT", 1 if serve.get("command") else 0)
    emit("SERVE_COMMAND", serve.get("command") or "")
    emit("SERVE_PORT", serve.get("port") or 4501)
    emit("SERVE_HEALTH_PATH", serve.get("health_path") or "/")
    emit("OBS_DB_REL", (cfg.get("observability") or {}).get("db") or "adws/adw_data/sssf.db")
    PROBE
    ) || { echo "observe: app-lane probe failed on $VM — VM left up for debugging" >&2; exit 1; }
    eval "$APP_ENV"
    APP_PORT="$SERVE_PORT"
    APP_DIR="\$HOME/app/$APP_PATH"      # expanded on the VM, not here
    OBS_DB="\$HOME/app/$OBS_DB_REL"     # roster's observability.db, VM-expanded

    # ── 1. app on the manifest's declared port ───────────────────────────────
    # Idempotent: observe is safe to re-run, and `just sbx mount` ends here, so a
    # second call must not stack a second server on the same port. A manifest
    # with no serve: block is a library/CLI app — skip the lane, do not fail.
    APP_STARTED=0
    if [ "$SERVE_PRESENT" != "1" ]; then
        echo "[2/6] app  skipped — no serve: in $APP_PATH/$APP_MANIFEST"
    else
        echo "[2/6] app  :$APP_PORT  ($APP_PATH)"
        if listening "$APP_PORT"; then
            echo "       already listening — leaving it alone"
            APP_STARTED=1
        else
            # All three detachment pieces are REQUIRED or ssh never returns: nohup
            # (survive session end), the redirect (release stdout/stderr), and
            # < /dev/null (release stdin). Dropping any one hangs this recipe.
            # PORT= goes BEFORE nohup: `nohup PORT=x cmd` makes nohup try to exec
            # a program literally named "PORT=x"; as a prefix on nohup the
            # assignment lands in its environment and the server inherits it.
            ssh "$HOST" "cd $APP_DIR && ( PORT=$APP_PORT nohup $SERVE_COMMAND > \$HOME/app-server.log 2>&1 < /dev/null & echo \$! )" \
                | sed 's/^/       started pid /'
            if ! wait_listen "$APP_PORT"; then
                echo "observe: app never bound :$APP_PORT — tail of ~/app-server.log:" >&2
                ssh "$HOST" 'tail -n 40 $HOME/app-server.log' >&2 || true
                exit 1
            fi
            echo "       up"
            APP_STARTED=1
        fi
    fi

    # ── 2. visualizer on 4600 ────────────────────────────────────────────────
    # VERIFIED in the plan: the visualizer EXITS when sssf.db is missing. Check
    # for the db before spending a start attempt, so the error names the real
    # cause instead of showing an empty port.
    echo "[3/6] obs  :$OBS_PORT"
    if ! ssh "$HOST" "test -f $OBS_DB"; then
        echo "observe: $OBS_DB is missing on $VM." >&2
        echo "         The visualizer exits immediately without it. That db is created by" >&2
        echo "         sandbox_mount/guest/provision.sh (step 8, 'trace db') — re-run SETUP:" >&2
        echo "           just sbx lifecycle setup {{RUN_ID}}" >&2
        exit 1
    fi
    if listening "$OBS_PORT"; then
        echo "       already listening — leaving it alone"
    else
        # SSSF_DB goes BEFORE nohup, not after: `nohup VAR=x cmd` makes nohup
        # try to exec a program literally named "VAR=x". As a prefix on nohup
        # the assignment lands in its environment and bun inherits it.
        # The db path is passed explicitly because it resolves against the
        # server's cwd, and the server runs from the visualizer app dir.
        ssh "$HOST" "cd $OBS_DIR && ( SSSF_DB=$OBS_DB nohup bun run server/index.ts > \$HOME/visualizer.log 2>&1 < /dev/null & echo \$! )" \
            | sed 's/^/       started pid /'
        if ! wait_listen "$OBS_PORT"; then
            echo "observe: visualizer never bound :$OBS_PORT — tail of ~/visualizer.log:" >&2
            ssh "$HOST" 'tail -n 40 $HOME/visualizer.log' >&2 || true
            echo "         If it says 'sssf.db not found', SETUP did not initialize the trace db:" >&2
            echo "           sandbox_mount/guest/provision.sh  ->  just sbx lifecycle setup {{RUN_ID}}" >&2
            exit 1
        fi
        echo "       up"
    fi

    # ── 3. proxy ─────────────────────────────────────────────────────────────
    # Retarget the proxy only when a server was started: a manifest with no
    # serve: block has nothing to expose. A fresh exeuntu VM proxies port 8000
    # (smallest EXPOSEd port >= 1024); set-public applies to the primary port
    # only — see the note printed at the end.
    if [ "$APP_STARTED" = 1 ]; then
        echo "[4/6] proxy -> :$APP_PORT, public"
        ssh exe.dev share port "$VM" "$APP_PORT"
        ssh exe.dev share set-public "$VM"
    else
        echo "[4/6] proxy skipped — no app server to expose"
    fi

    # ── 4. record ────────────────────────────────────────────────────────────
    echo "[5/6] recording ports"
    if [ "$APP_STARTED" = 1 ]; then
        "$RR" set {{RUN_ID}} "ports={\"app\":$APP_PORT,\"obs\":$OBS_PORT}"
    else
        "$RR" set {{RUN_ID}} "ports={\"obs\":$OBS_PORT}"
    fi

    # ── 5. verify ────────────────────────────────────────────────────────────
    # curl with no auth of any kind — that is the whole point of the app check.
    # No -L: a redirect is a result here, not something to follow.
    echo "[6/6] verifying"
    code_of() {
        curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" || echo 000
    }

    # The public flag can lag the API call by a beat; retry before failing. The
    # health path is the manifest's (default /); a run with no server skips it.
    if [ "$APP_STARTED" = 1 ]; then
        APP_CODE=000
        for _ in 1 2 3 4 5 6; do
            APP_CODE=$(code_of "https://$HOST$SERVE_HEALTH_PATH")
            [ "$APP_CODE" = "200" ] && break
            sleep 2
        done
        if [ "$APP_CODE" != "200" ]; then
            echo "observe: app returned $APP_CODE anonymously at https://$HOST$SERVE_HEALTH_PATH (want 200)" >&2
            echo "         VM left up. Check: ssh exe.dev share show $VM" >&2
            exit 1
        fi
        echo "       app  200 anonymous"
    else
        echo "       app  skipped (no serve: in manifest)"
    fi

    # 307/401 anonymously is CORRECT for the obs port: alternate ports stay
    # auth-gated to users with VM access. Only a dead proxy (000) or a 5xx is a
    # real failure; anything else means the port is reachable and gated.
    OBS_CODE=$(code_of "https://$HOST:$OBS_PORT/")
    if [ "$OBS_CODE" = "000" ] || [ "$OBS_CODE" -ge 500 ]; then
        echo "observe: obs port unreachable at https://$HOST:$OBS_PORT/ (got $OBS_CODE)" >&2
        exit 1
    fi
    echo "       obs  $OBS_CODE anonymous — expected, it is owner-gated"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    if [ "$APP_STARTED" = 1 ]; then
        echo "  app  https://$HOST$SERVE_HEALTH_PATH"
    else
        echo "  app  (none — no serve: in manifest)"
    fi
    echo "  obs  https://$HOST:$OBS_PORT/"
    echo "════════════════════════════════════════════════════════════"
    echo "  The obs URL opens fine in a browser already signed in to exe.dev."
    echo "  Ports 3000-9999 are auto-forwarded by the proxy but auth-gated;"
    if [ "$APP_STARTED" = 1 ]; then
        echo "  only ONE port can ever be anonymous, and that is $APP_PORT."
    else
        echo "  no port is anonymous this run — the manifest declares no serve: block."
    fi
