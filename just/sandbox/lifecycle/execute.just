# ─── just/sandbox/execute.just — PHASE 4: EXECUTE ─────────────────────────
# Out-of-sandbox orchestration. IMPORTED by the root justfile, so this file
# defines no `set` lines and no top-level variables: settings and variables are
# shared with the root and with the five sibling phase files, and a duplicate is
# either an error or a silent shadow. Everything below is local shell state.
#
# Three ways to drive a mounted sandbox:
#   just sbx run cmd            — generic escape hatch, synchronous, prints output
#   just sbx lifecycle execute  — the default: full SDLC, DETACHED, returns a PID
#   just sbx run agent          — hand off to pi and keep talking to it
#
# Nothing here ever destroys a VM. A failure reports and exits non-zero with the
# box left alive, because the evidence you need to diagnose it is on that box.
# Teardown is always a separate, explicit decision.
#
# No sandbox-minted credentials exist: the only host-only credential is the
# exe.dev account, and it never leaves the host. We also never ask ssh to forward
# host env (no SendEnv), so nothing from .env leaks over.
#
# SESSION TRACKING (GitHub issues). When issues are enabled (SSSF_ISSUES != '0',
# default on) and the roster is TARGET mode (app.repo set), execute opens one
# issue per run in the app's own repo BEFORE the SDLC is launched — title = the
# instruction verbatim, label sssf:running — and spawns a detached HOST watcher
# that adds one milestone comment mid-run and closes the issue with the full
# audit record when the session ends. `gh` runs on the host only; the VM never
# sees a GitHub credential. SSSF_ISSUES=0 disables it; a roster with no app.repo
# (vendored mode) skips with a named message. Every tracker call is best-effort:
# it warns and never fails the execute.

# usage: just sbx lifecycle execute <run-id> "add a word-count badge to the editor footer"
#        just sbx lifecycle execute <run-id> prompts/06-redesign-quiet-room.md adws/adw_sssf_config/sssf.frontier.config.yaml
#
# PROMPT is passed through verbatim: adw_plan_build_test resolves it with
# utils.resolve_prompt(), so a path to a file IN THE SANDBOX'S CHECKOUT reads as
# that file's contents and anything else stays inline text. For fan-out, a path
# is the better handle — every arm then provably runs the same bytes.
#
# CONFIG is optional and picks the roster. It is appended as a trailing
# `--config` to `adw sdlc`, whose recipe already passes "$@" through to
# argparse; argparse keeps the LAST --config, so this wins over the module
# default without the module needing to know about us. SSSF_CONFIG (the env
# route) cannot work here at all: `ssh vm "cmd"` reads no profile and carries no
# environment. When omitted it defaults to the per-sandbox config FILL ships at
# /home/exedev/sssf_config.yaml — and a MISSING file is a hard failure, not a
# silent fall back to the repo default.

# ADW picks WHICH workflow runs — any recipe name from `just adw` (sdlc,
# simple-sdlc, plan-build-test-quality, scout, …). It defaults to `sdlc`, so
# every existing call site is unchanged. It is a separate argument rather than
# something smuggled into PROMPT because the recipe name is the FIRST token
# after `adw` and the prompt is quoted as one word; concatenating them would put
# the prompt where just expects a recipe.

# EXTRA is appended verbatim after the config, for the ADW's own flags — most
# usefully `--adw-id <id>`, which rejoins an existing session so the agents keep
# their pi context instead of starting cold. Interpolated as typed, like
# `run cmd`: these are flags, not prose, and re-quoting them would break pairs.

# the default: full SDLC inside the sandbox, detached — returns a PID. CONFIG picks the roster, ADW the workflow
execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA:
    #!/usr/bin/env bash
    set -euo pipefail
    RR="{{justfile_directory()}}/sandbox_mount/host/run_record.py"
    VM=$("$RR" get {{RUN_ID}} vm_name)
    [ -n "$VM" ] || { echo "execute {{RUN_ID}}: no vm_name in the run record — is it mounted?" >&2; exit 1; }

    # quote() hands bash a correct single-quoted literal, so apostrophes in the
    # prompt survive hop 1 (just -> host bash). printf %q then survives hop 2
    # (host bash -> the remote login shell), which parses the ssh command string.
    PROMPT={{ quote(PROMPT) }}
    Q=$(printf '%q' "$PROMPT")

    # CONFIG picks the roster. When the caller does not pass one, use the
    # per-sandbox config FILL ships at a fixed absolute path. A missing file FAILS
    # rather than silently falling back to the repo default — that drift is exactly
    # what this change removes. An explicit CONFIG still wins (fan-out with a
    # pinned roster keeps working).
    CONFIG={{ quote(CONFIG) }}
    if [ -z "$CONFIG" ]; then
        CONFIG="/home/exedev/sssf_config.yaml"
    fi
    if ! ssh "$VM".exe.xyz "test -f $(printf '%q' "$CONFIG")" < /dev/null; then
        echo "execute {{RUN_ID}}: roster $CONFIG is missing on $VM — run 'just sbx lifecycle fill {{RUN_ID}}' first" >&2
        exit 1
    fi
    CFG_ARG=" --config $(printf '%q' "$CONFIG")"
    echo "→ roster: $CONFIG"

    # ── issue tracking (best-effort; never fails the execute) ────────────────
    # Decide once, here, whether this run gets an issue: disabled entirely by
    # SSSF_ISSUES=0, or skipped in vendored mode (no app.repo — there is no
    # separate app repo to file into). Both are named skips, not failures.
    TRACKER="{{justfile_directory()}}/sandbox_mount/host/issue_tracker.py"
    ISSUES_ON=1
    SINCE=""
    if [ "${SSSF_ISSUES:-1}" = "0" ]; then
        ISSUES_ON=0
        echo "→ issues: disabled (SSSF_ISSUES=0) — skipping issue tracking"
    else
        # Prefer the HOST roster when SSSF_CONFIG is set (the usual case); else
        # read the per-sandbox copy FILL shipped. Same app: block awk as
        # mount/fill/teardown/harvest. Any failure here must not abort.
        ROSTER_TEXT=""
        if [ -n "${SSSF_CONFIG:-}" ] && [ -f "${SSSF_CONFIG}" ]; then
            ROSTER_TEXT="$(cat "${SSSF_CONFIG}" 2>/dev/null || true)"
        else
            ROSTER_TEXT="$(ssh "$VM".exe.xyz "cat $(printf '%q' "$CONFIG")" 2>/dev/null || true)"
        fi
        APP_REPO_ISSUES="$(printf '%s\n' "$ROSTER_TEXT" | awk '
          /^app:[[:space:]]*$/ { a=1; next }
          /^[^[:space:]]/      { a=0 }
          a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
        ')"
        if [ -z "$APP_REPO_ISSUES" ]; then
            ISSUES_ON=0
            echo "→ issues: vendored mode (no app.repo) — skipping issue tracking"
        fi
    fi
    if [ "$ISSUES_ON" = 1 ]; then
        # Captured BEFORE launch: the watcher matches the session it watches by
        # started_at >= since, because the adw_id does not exist yet.
        SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        uv run "$TRACKER" open {{RUN_ID}} --instruction "$PROMPT" --chain "{{ADW}}" \
            || echo "!! issue open failed (best-effort) — continuing without it" >&2
    fi

    # All three detachment pieces are mandatory or ssh never returns: nohup
    # (survive session end), the redirect (release stdout/stderr), < /dev/null
    # (release stdin). `echo $!` inside the subshell is what gives us the PID —
    # \$! so it is expanded by the REMOTE shell, not here.
    #
    # --shell bash --shell-arg -c is mandatory too: the repo's justfile sets
    # shell := ["zsh", "-ic"] and zsh is not in the exeuntu image (installing it
    # is ~35s of apt for no benefit). `adw sdlc` is the module recipe.
    #
    # NOTE: run.log is truncated on every execute — one detached SDLC per
    # sandbox at a time is the intended shape. Pull the old log first if you
    # care about it.
    echo "→ execute {{RUN_ID}} on $VM (detached): adw {{ADW}} $PROMPT"
    # tail -n 1: the PID is the last thing printed, so any stray remote stdout
    # (a shell rc that talks, an motd) does not corrupt the capture.
    # The trailing `< /dev/null` on the LOCAL ssh is separate from the one inside
    # the remote command, and both are needed. The inner one detaches the remote
    # SDLC from its stdin; this outer one stops ssh reading the CALLER's stdin.
    # Without it a `while read ... done < arms.map` loop around this recipe runs
    # exactly once — ssh eats the rest of the map and the loop sees EOF.
    PID=$(ssh "$VM".exe.xyz "cd app && ( nohup just --shell bash --shell-arg -c adw {{ADW}} $Q$CFG_ARG {{EXTRA}} > run.log 2>&1 < /dev/null & echo \$! )" < /dev/null | tail -n 1)

    # A non-numeric answer means the remote shell printed an error where the PID
    # should be. Fail here rather than writing garbage into the record.
    case "$PID" in
        ''|*[!0-9]*) echo "execute {{RUN_ID}}: expected a PID, got: ${PID:-<empty>}" >&2; exit 1 ;;
    esac

    "$RR" set {{RUN_ID}} pid="$PID"
    echo "→ pid $PID recorded; SDLC is running detached"

    # ── issue watcher (best-effort; host process, gh needs the host) ────────
    # Same three detachment pieces as the SDLC: nohup, redirect, < /dev/null.
    # The watcher polls the VM trace every ~30s and closes the issue with the
    # outcome; if it dies, `teardown` and `just sbx manage sync-issues` are the
    # backstops, which is why this is never allowed to fail the execute.
    if [ "$ISSUES_ON" = 1 ]; then
        mkdir -p .sandbox/runs
        ( nohup uv run "$TRACKER" watch {{RUN_ID}} --since "$SINCE" \
            > ".sandbox/runs/{{RUN_ID}}.watcher.log" 2>&1 < /dev/null & echo "→ issue watcher pid $!" )
    fi
    echo "→ watch it:  just sbx run cmd {{RUN_ID}} 'tail -f run.log'"
