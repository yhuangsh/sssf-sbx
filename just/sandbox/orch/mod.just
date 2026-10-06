# just/sandbox/orch/mod.just — boot an agent at the ORCHESTRATION level.
#
# There are two levels, and booting the wrong one is the classic mistake:
#
#   just adw <recipe>      FACTORY level. The recipes in just/adws.just over
#                          adws/ — plan, build, test, review, document. They are
#                          identical on the host and inside a sandbox, which is
#                          exactly why they must only be DRIVEN through a sandbox
#                          phase: `just sbx lifecycle execute`, or
#                          `just sbx run cmd ... 'just --shell bash --shell-arg -c
#                          adw <recipe> ...'`. Running `just adw sdlc "..."`
#                          directly here runs the factory on your laptop, which is
#                          the one thing this whole system exists to prevent.
#
#   just sbx orch cc <roster>   ORCHESTRATION level. Reads
#   just sbx orch pi <roster>   .claude/skills/sssf-sandbox-orchestrator/SKILL.md
#                          and drives the phases: mount, execute, observe, harvest,
#                          tear down. Belongs on the HOST: it needs the exe.dev
#                          account, which never reaches a sandbox.
#
# The roster is a MANDATORY argument. Booting the orchestrator without one is not
# a mode: the roster is the per-app input, so the session is FOCUSED on the app it
# names. The recipe validates the file, resolves it to an ABSOLUTE path (the
# orchestrator cd's around; a relative SSSF_CONFIG would silently break every
# roster-consuming command after the first cd), and EXPORTS it as SSSF_CONFIG into
# the launched agent's environment — so every roster-consuming just command the
# orchestrator runs hits THAT roster, the explicit arg winning over any .env value.
#
# The roster's `app:` block (`repo`/`ref`/`path`/`manifest`) is the per-app input.
# With `repo` set, FILL clones that repo to `~/app/<path>` in the VM, the run
# branch `sbx/<id>` and every ADW commit live on that clone, and HARVEST bundles
# from it — the factory clone stays byte-identical across apps. No `repo` keeps
# the payload vendored in the factory clone. The VM tag derives from `app.repo`
# (or an explicit mount arg) and is recorded in the run record.
#
# A module inherits nothing, so the settings are repeated here with one more `..`
# than the parent.
set working-directory := '../../..'
set positional-arguments
set dotenv-load

# list the orchestrator harnesses
default:
    @just --list sbx::orch

# cc / pi share their whole body — validation, absolutize, app:-block parse,
# boot banner — and differ only in the resume mechanism and the launch line.
# KEEP THE TWO BODIES IN SYNC (like roster_keys.sh / gate E's second copy).
#
# RESUME (cc): session-local, unlike pi's deterministic id. `claude
# --dangerously-skip-permissions --continue` from this repo root continues the
# most recent orchestrator conversation; `--resume` picks a specific one from the
# picker. The banner below prints this too, so it is discoverable at boot.

# boot the sandbox orchestrator (Claude Code), focused on this roster's app
cc SSSF_CONFIG_FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    # Validate BEFORE anything launches: the roster is the whole point of the boot.
    [ -f "{{SSSF_CONFIG_FILE}}" ] || { echo "[orch] roster file '{{SSSF_CONFIG_FILE}}' not found" >&2; exit 1; }
    # Absolute path: working-directory is the repo root, but the orchestrator cd's
    # around; a relative SSSF_CONFIG would silently break every roster-consuming
    # command after the first cd. cd/pwd, not realpath (portable).
    ROSTER="$(cd "$(dirname "{{SSSF_CONFIG_FILE}}")" && pwd)/$(basename "{{SSSF_CONFIG_FILE}}")"
    # EXPORT: every roster-consuming just command the agent runs (mount, fill,
    # doctor, harvest, adw …) must hit THIS roster. Exported here, it wins over
    # any SSSF_CONFIG dotenv-load pulled in from .env.
    export SSSF_CONFIG="$ROSTER"
    # app: block, same awk as mount.just/create.just (no yq on the host).
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
    # boot banner: harness, roster, the app this session is focused on, resume.
    printf '[orch] harness:  claude-code\n[orch] roster:   %s (SSSF_CONFIG exported)\n[orch] app.repo: %s\n[orch] app.path: %s\n[orch] resume:   claude --dangerously-skip-permissions --continue   (from this repo root; continues the most recent orchestrator conversation)\n' \
      "$ROSTER" "${APP_REPO:-<none — vendored mode>}" "${APP_PATH:-<unset>}"
    claude --dangerously-skip-permissions "Read and execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md, then the cookbook .claude/skills/sssf-sandbox-orchestrator/cookbooks/focus_on_app.md. SSSF_CONFIG is already exported and names your roster: $ROSTER. Every roster-consuming just command uses it — do not set or override it."

# boot the sandbox orchestrator (pi), focused on this roster's app
pi SSSF_CONFIG_FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    # Validate BEFORE anything launches: the roster is the whole point of the boot.
    [ -f "{{SSSF_CONFIG_FILE}}" ] || { echo "[orch] roster file '{{SSSF_CONFIG_FILE}}' not found" >&2; exit 1; }
    # Absolute path: working-directory is the repo root, but the orchestrator cd's
    # around; a relative SSSF_CONFIG would silently break every roster-consuming
    # command after the first cd. cd/pwd, not realpath (portable).
    ROSTER="$(cd "$(dirname "{{SSSF_CONFIG_FILE}}")" && pwd)/$(basename "{{SSSF_CONFIG_FILE}}")"
    # EXPORT: every roster-consuming just command the agent runs (mount, fill,
    # doctor, harvest, adw …) must hit THIS roster. Exported here, it wins over
    # any SSSF_CONFIG dotenv-load pulled in from .env.
    export SSSF_CONFIG="$ROSTER"
    # app: block, same awk as mount.just/create.just (no yq on the host).
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
    # RESUME (pi): a DETERMINISTIC session id derived from the roster basename.
    # pi's --session-id CREATES the session if missing and CONTINUES it if it
    # exists, so re-running this same command resumes this orchestrator's context
    # automatically. Strip the sssf./.config.yaml shell, sanitize to [a-z0-9-]
    # (same idiom as create.just's tag derivation), prefix orch- (hello -> orch-hello).
    base=$(basename "$ROSTER")                      # sssf.hello.config.yaml
    name=${base#sssf.}; name=${name%.config.yaml}   # -> hello
    name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')
    # fallback for names that strip to nothing (e.g. sssf.config.yaml): sanitize the full basename
    [ -n "$name" ] || name=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')
    SID="orch-$name"                                # orch-hello
    # boot banner: harness, roster, the app this session is focused on, resume.
    printf '[orch] harness:  pi\n[orch] roster:   %s (SSSF_CONFIG exported)\n[orch] app.repo: %s\n[orch] app.path: %s\n[orch] resume:   re-run this same command — pi --session-id %s creates-or-continues\n' \
      "$ROSTER" "${APP_REPO:-<none — vendored mode>}" "${APP_PATH:-<unset>}" "$SID"
    pi --session-id "$SID" "Read and execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md, then the cookbook .claude/skills/sssf-sandbox-orchestrator/cookbooks/focus_on_app.md. SSSF_CONFIG is already exported and names your roster: $ROSTER. Every roster-consuming just command uses it — do not set or override it."

# To steer the agent already running INSIDE a mounted sandbox, use the run layer
# instead:  just sbx run agent RUN_ID "<prompt>"  (see just/sandbox/run/mod.just).
# It is host-side like everything here, but it drives pi on the VM over a
# resumable --session-id. There was briefly a `steer` alias for it; two names
# for one behavior, split across two files, is worse than one.
#
# There was also an `orchestrate-with "<task>"` that booted the orchestrator with
# a task already in hand. Dropped: `just sbx orch cc <roster>` and then typing the
# task is the same thing with one fewer recipe to keep in sync.
