# just/local.just — the `local` namespace: the full sssf workflow on the HOST,
# with the payload in a local clone of the app. No VM, no exe.dev, no ssh, no
# detachment — you watch the chain run in your own terminal.
#
# NOT the factory repo's own just/local.just (that is a different file in a
# different repo). THIS kernel's `local` is the local development lane.
#
# The workflow is identical to `just sbx`: same rosters, same chains, same
# gates, same GitHub-issue tracking, same trace. What changes is WHERE the
# payload lives. The roster's `app:` block gains an optional `local_path:`
# naming an existing clone OUTSIDE this kernel tree:
#
#   app:
#     repo: https://github.com/<owner>/<name>.git
#     local_path: ~/projects/<name>     # LOCAL mode payload (this lane)
#     manifest: sssf.app.yaml
#
# `git_helper.payload_root()` resolves local_path first, so the chains commit
# to that clone's run branch `sbx/<run-id>`. The kernel is NEVER the payload of
# an app run — a local_path inside this repo is a named error.
#
# A module inherits NOTHING from its parent — not variables, not settings, and
# its working directory defaults to its own file's directory. Hence the `set`
# lines below; `..` puts every recipe at the repo root (same shape as
# just/adws.just).
set working-directory := '..'
set positional-arguments
set dotenv-load

# list the local development commands
default:
    @just --list local

# interactively scaffold a GitHub app repo + roster for LOCAL development (clone on the host, no VM)
scaffold REPO='':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{REPO}}" ]; then
        exec uv run sandbox_mount/host/scaffold.py --preset local "{{REPO}}"
    else
        exec uv run sandbox_mount/host/scaffold.py --preset local
    fi

# host-side arming + payload prep: resolve local_path, clone-if-missing, clean
# check, create the run branch sbx/<run-id>, write the run record (vm_name=local)
mount RUN_ID:
    #!/usr/bin/env bash
    set -euo pipefail

    RR="sandbox_mount/host/run_record.py"

    # SSSF_CONFIG is REQUIRED — the shared guard prints THE named error and exits.
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)

    # ── app: block (same flat two-space awk as just/sandbox/mount.just) ───────
    APP_REPO=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    APP_REF=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+ref:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    APP_MANIFEST=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+manifest:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    APP_LOCAL=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+local_path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    APP_MANIFEST="${APP_MANIFEST:-sssf.app.yaml}"

    # ── resolve the payload: local_path wins, and it must NOT be inside the
    # kernel tree — the kernel is never the payload of an app run ─────────────
    KERNEL_ROOT="$(pwd -P)"
    if [ -z "$APP_LOCAL" ]; then
        echo "[local mount] roster has no app.local_path — run 'just local scaffold' or add local_path: to the app: block" >&2
        exit 1
    fi
    LOCAL_PATH="${APP_LOCAL/#\~/$HOME}"
    case "$LOCAL_PATH" in
        /*) ;;
        *)  LOCAL_PATH="$KERNEL_ROOT/$LOCAL_PATH" ;;   # relative -> resolves inside the kernel, refused below
    esac
    if [ -e "$LOCAL_PATH" ]; then
        RESOLVED="$(cd "$LOCAL_PATH" && pwd -P)"
    else
        RESOLVED="$LOCAL_PATH"
    fi
    case "$RESOLVED" in
        "$KERNEL_ROOT"|"$KERNEL_ROOT"/*)
            echo "[local mount] app.local_path '$LOCAL_PATH' is inside the kernel tree '$KERNEL_ROOT' — the kernel is never the payload of an app run; point local_path at a clone OUTSIDE the kernel" >&2
            exit 1 ;;
    esac

    # ── clone-if-missing: payload_root only resolves; MOUNT does the cloning ──
    if ! git -C "$LOCAL_PATH" rev-parse --git-dir >/dev/null 2>&1; then
        if [ -z "$APP_REPO" ]; then
            echo "[local mount] app.local_path '$LOCAL_PATH' is not a git repo and app.repo is unset — nothing to clone from" >&2
            exit 1
        fi
        echo "→ cloning $APP_REPO -> $LOCAL_PATH"
        mkdir -p "$(dirname "$LOCAL_PATH")"
        git clone "$APP_REPO" "$LOCAL_PATH"
        if [ -n "$APP_REF" ]; then
            git -C "$LOCAL_PATH" checkout "$APP_REF"
        fi
    fi

    # ── validate: manifest present, working tree clean ────────────────────────
    if [ ! -f "$LOCAL_PATH/$APP_MANIFEST" ]; then
        echo "[local mount] manifest '$APP_MANIFEST' missing at $LOCAL_PATH/$APP_MANIFEST — the app is not sssf-armed" >&2
        exit 1
    fi
    if [ -n "$(git -C "$LOCAL_PATH" status --porcelain)" ]; then
        echo "[local mount] working tree at $LOCAL_PATH is dirty — the run branch must start clean; commit or stash first" >&2
        exit 1
    fi

    # ── run branch sbx/<run-id> (create or switch) ────────────────────────────
    BRANCH="sbx/{{RUN_ID}}"
    if git -C "$LOCAL_PATH" show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git -C "$LOCAL_PATH" switch "$BRANCH"
    else
        git -C "$LOCAL_PATH" switch -c "$BRANCH"
    fi

    # ── run record: vm_name=local (tolerated free string), commit + factory sha ─
    "$RR" create "{{RUN_ID}}" >/dev/null 2>&1 || true   # reuse an existing record
    "$RR" set "{{RUN_ID}}" \
        vm_name=local \
        commit_sha="$(git -C "$LOCAL_PATH" rev-parse HEAD)" \
        factory_sha="$(git rev-parse HEAD)"

    printf '\nmounted: %s (local)\n  payload: %s\n  branch:  %s\n  execute: just local execute %s sdlc "<prompt>"\n  ui:      just local ui\n  doctor:  just local doctor\n' \
        "{{RUN_ID}}" "$LOCAL_PATH" "$BRANCH" "{{RUN_ID}}"

# run the chosen chain host-side, FOREGROUND, against the local clone.
# GitHub-issue hooks wrap it exactly like the sandbox lane (issue opens before,
# closes after with the outcome, labeled sssf:local).
execute RUN_ID CHAIN PROMPT:
    #!/usr/bin/env bash
    set -uo pipefail

    RR="sandbox_mount/host/run_record.py"
    TRACKER="sandbox_mount/host/issue_tracker.py"

    VM=$("$RR" get {{RUN_ID}} vm_name 2>/dev/null) || {
        echo "[local execute] no run record for {{RUN_ID}} — run 'just local mount {{RUN_ID}}' first" >&2; exit 1; }
    if [ "$VM" != "local" ]; then
        echo "[local execute] run {{RUN_ID}} is not a local run (vm_name='${VM:-<unset>}') — use 'just sbx lifecycle execute' for a sandbox run" >&2
        exit 1
    fi

    # Resolve the payload the same way mount did; the pushed run branch is proof
    # the clone is armed and on the right branch.
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
    export SSSF_CONFIG="$ROSTER"
    APP_LOCAL=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+local_path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    LOCAL_PATH="${APP_LOCAL/#\~/$HOME}"
    case "$LOCAL_PATH" in
        /*) ;;
        *)  LOCAL_PATH="$(pwd -P)/$LOCAL_PATH" ;;
    esac
    BRANCH="sbx/{{RUN_ID}}"
    CUR=$(git -C "$LOCAL_PATH" branch --show-current 2>/dev/null || true)
    if [ "$CUR" != "$BRANCH" ]; then
        echo "[local execute] payload $LOCAL_PATH is on '${CUR:-<none>}', not '$BRANCH' — run 'just local mount {{RUN_ID}}' first" >&2
        exit 1
    fi

    PROMPT={{ quote(PROMPT) }}

    # ── issue tracking (best-effort; never fails the execute) ────────────────
    ISSUES_ON=1
    if [ "${SSSF_ISSUES:-1}" = "0" ]; then
        ISSUES_ON=0
        echo "→ issues: disabled (SSSF_ISSUES=0) — skipping issue tracking"
    fi
    if [ "$ISSUES_ON" = 1 ]; then
        uv run "$TRACKER" open {{RUN_ID}} --instruction "$PROMPT" --chain "{{CHAIN}}" --local \
            || echo "!! issue open failed (best-effort) — continuing without it" >&2
    fi

    echo "→ execute {{RUN_ID}} local: adw {{CHAIN}} $PROMPT"
    echo "→ watching live — foreground, no detachment"
    RC=0
    just adw "{{CHAIN}}" "$PROMPT" || RC=$?

    if [ "$ISSUES_ON" = 1 ]; then
        OUTCOME=accepted
        [ "$RC" -eq 0 ] || OUTCOME=failed
        uv run "$TRACKER" close {{RUN_ID}} --outcome "$OUTCOME" --local \
            || echo "!! issue close failed (best-effort) — continuing" >&2
    fi
    exit "$RC"

# serve the trace visualizer against the local adws/adw_data/sssf.db
ui:
    #!/usr/bin/env bash
    set -euo pipefail
    DB="$(pwd -P)/adws/adw_data/sssf.db"
    echo "→ visualizer: http://localhost:4601  (api :4600, db: adws/adw_data/sssf.db)"
    cd .claude/skills/sssf/apps/visualizer
    bun install
    (SSSF_DB="$DB" bun run server/index.ts &)
    bunx vite

# local arming preflight: host tools, SSSF_CONFIG, provider keys, payload
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh) || exit 1
    ok=0
    chk()  { if eval "$2" >/dev/null 2>&1; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; ok=1; fi; }
    warn() { printf '  WARN  %s\n' "$1"; }
    chk "uv present"               'command -v uv'
    chk "bun present"              'command -v bun'
    chk "just present"             'command -v just'
    chk "roster provider keys set" 'sandbox_mount/host/roster_keys.sh'

    APP_REPO=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    APP_MANIFEST=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+manifest:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    APP_MANIFEST="${APP_MANIFEST:-sssf.app.yaml}"
    APP_LOCAL=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+local_path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    LOCAL_PATH="${APP_LOCAL/#\~/$HOME}"
    if [ -z "$LOCAL_PATH" ]; then
        printf '  FAIL  app.local_path set — run '\''just local scaffold'\'' or add local_path: to the app: block\n'
        ok=1
    else
        case "$LOCAL_PATH" in /*) ;; *) LOCAL_PATH="$(pwd -P)/$LOCAL_PATH" ;; esac
        if git -C "$LOCAL_PATH" rev-parse --git-dir >/dev/null 2>&1; then
            printf '  ok    app.local_path %s is a git repo\n' "$LOCAL_PATH"
            if [ -f "$LOCAL_PATH/$APP_MANIFEST" ]; then
                printf '  ok    manifest %s present\n' "$APP_MANIFEST"
            else
                printf '  FAIL  manifest %s missing at %s/%s\n' "$APP_MANIFEST" "$LOCAL_PATH" "$APP_MANIFEST"
                ok=1
            fi
            if [ -n "$(git -C "$LOCAL_PATH" status --porcelain 2>/dev/null)" ]; then
                warn "$LOCAL_PATH has a dirty working tree (mount needs it clean)"
            else
                printf '  ok    %s working tree clean\n' "$LOCAL_PATH"
            fi
        elif [ -n "$APP_REPO" ] && git ls-remote "$APP_REPO" >/dev/null 2>&1; then
            printf '  ok    app.local_path %s missing but app.repo is reachable (mount will clone)\n' "$LOCAL_PATH"
        else
            printf '  FAIL  app.local_path %s is not a git repo and app.repo is unreachable\n' "$LOCAL_PATH"
            ok=1
        fi
    fi

    [ "$ok" -eq 0 ] && echo "  local doctor: OK" || { echo "  local doctor: FAILED"; exit 1; }

# boot the LOCAL orchestrator (cc or pi), focused on this roster's app.
# Same contract as `just sbx orch cc|pi`, but drives `just local mount/execute/ui`.
orch HARNESS SSSF_CONFIG_FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    HARNESS="{{HARNESS}}"
    case "$HARNESS" in
        cc|pi) ;;
        *) echo "[orch] usage: just local orch cc|pi <sssf-config-file>" >&2; exit 2 ;;
    esac
    # Validate BEFORE anything launches: the roster is the whole point of the boot.
    [ -f "{{SSSF_CONFIG_FILE}}" ] || { echo "[orch] roster file '{{SSSF_CONFIG_FILE}}' not found" >&2; exit 1; }
    # Absolute path: working-directory is the repo root, but the orchestrator cd's
    # around; a relative SSSF_CONFIG would silently break every roster-consuming
    # command after the first cd. cd/pwd, not realpath (portable).
    ROSTER="$(cd "$(dirname "{{SSSF_CONFIG_FILE}}")" && pwd)/$(basename "{{SSSF_CONFIG_FILE}}")"
    # EXPORT: every roster-consuming just command the agent runs (mount, execute,
    # ui, doctor, adw …) must hit THIS roster — it wins over any .env value.
    export SSSF_CONFIG="$ROSTER"
    # app: block, same awk as mount (no yq on the host).
    APP_REPO=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
    ' "$ROSTER" 2>/dev/null || true)
    APP_PATH=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER" 2>/dev/null || true)
    APP_LOCAL=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+local_path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER" 2>/dev/null || true)
    KICKOFF="Read and execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md, then the cookbook .claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md. SSSF_CONFIG is already exported and names your roster: $ROSTER. Every roster-consuming just command uses it — do not set or override it."

    if [ "$HARNESS" = "cc" ]; then
        printf '[orch] harness:  local/claude-code\n[orch] roster:   %s (SSSF_CONFIG exported)\n[orch] app.repo: %s\n[orch] app.path: %s\n[orch] app.local_path: %s\n[orch] resume:   claude --dangerously-skip-permissions --continue   (from this repo root; continues the most recent local orchestrator conversation)\n' \
            "$ROSTER" "${APP_REPO:-<none — vendored mode>}" "${APP_PATH:-<unset>}" "${APP_LOCAL:-<unset — run 'just local scaffold'>}"
        claude --dangerously-skip-permissions "$KICKOFF"
    else
        # RESUME (pi): a DETERMINISTIC session id derived from the roster basename,
        # prefixed `local-` so a user running BOTH the sandbox (`orch-`) and local
        # orchestrators for the same app never shares a session. Strip the
        # sssf./.config.yaml shell, sanitize to [a-z0-9-], fallback to the full
        # basename (same idiom as just/sandbox/orch/mod.just).
        base=$(basename "$ROSTER")                      # sssf.hello.config.yaml
        name=${base#sssf.}; name=${name%.config.yaml}   # -> hello
        name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')
        [ -n "$name" ] || name=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')
        SID="local-$name"                               # local-hello
        printf '[orch] harness:  local/pi\n[orch] roster:   %s (SSSF_CONFIG exported)\n[orch] app.repo: %s\n[orch] app.path: %s\n[orch] app.local_path: %s\n[orch] resume:   re-run this same command — pi --session-id %s creates-or-continues\n' \
            "$ROSTER" "${APP_REPO:-<none — vendored mode>}" "${APP_PATH:-<unset>}" "${APP_LOCAL:-<unset — run 'just local scaffold'>}" "$SID"
        pi --session-id "$SID" "$KICKOFF"
    fi
