# just/sandbox/setup.just — PHASE 3 of 6: SETUP.
#
# Imported by the root justfile (not a module), so it shares the root's scope
# and settings. No `set` lines here on purpose: duplicating `dotenv-load` or
# `positional-arguments` is a hard error at parse time.
#
# What this phase does: stream the HOST checkout's provision.sh into the sandbox
# over ssh stdin (never the copy inside the VM's clone — the gates A–E below are
# host-side, so the provisioner that runs must be the same version as the gate
# that checks its work; origin is the engineer's fork and may lag the working
# tree, so host-streaming is what keeps provisioner and gate in lockstep), wait
# for its sentinel, then run the five-assertion
# health gate. Nothing here creates or
# destroys a VM. On failure it prints how to get into the box and exits
# non-zero, because a gate that auto-destroys throws away the evidence.
#
# The gate reads no host secret: C/D/E exercise the sandbox's own pi and the
# keys FILL shipped into app/.env, which is the only credential path. `ssh host
# cmd` carries NO environment, so every pi call sources app/.env first. They still
# run INSIDE the sandbox so the gate proves the sandbox's own egress works, not
# the host's.

# CONFIG picks which roster the gate checks. It has to be an ARGUMENT: C used to
# read $SSSF_CONFIG out of the remote environment, but `ssh host 'cmd'` carries
# no environment at all, so that read always fell through to the default. On a
# fan-out where each arm runs a different roster, every arm was gated against
# models it would never call — the gate passed and told you nothing. When the
# argument is empty it defaults to the per-sandbox config FILL ships at
# /home/exedev/sssf_config.yaml, and a MISSING file fails the gate rather than
# silently gating against the repo default. Pass the same path here that you pass
# to `just sbx lifecycle execute`.

# phase 3: provision the sandbox, then gate it (never destroys the VM). CONFIG picks the roster the gate checks
setup RUN_ID CONFIG="":
    #!/usr/bin/env bash
    set -euo pipefail

    RR="sandbox_mount/host/run_record.py"
    VM=$("$RR" get {{RUN_ID}} vm_name)
    SHA=$("$RR" get {{RUN_ID}} commit_sha)
    # factory_sha is empty on records that predate the field; gate A tolerates that.
    FACTORY_SHA=$("$RR" get {{RUN_ID}} factory_sha)

    # run_record prints an empty line for an unset field, so emptiness is the
    # real check — a missing vm_name means CREATE never finished.
    [ -n "$VM" ]  || { echo "[setup] run record {{RUN_ID}} has no vm_name — run: just sbx lifecycle create {{RUN_ID}}" >&2; exit 1; }
    [ -n "$SHA" ] || { echo "[setup] run record {{RUN_ID}} has no commit_sha — run: just sbx lifecycle fill {{RUN_ID}}" >&2; exit 1; }

    HOST="$VM.exe.xyz"
    # ConnectTimeout only: every *.exe.xyz shares one host key and the wildcard
    # known_hosts entry is already installed, so ssh is non-interactive already.
    SSH=(ssh -o ConnectTimeout=15 "$HOST")

    echo "[setup] run {{RUN_ID}}  vm ${VM}  sha ${SHA}"

    # Every failure below routes through here: report, hand over the debug
    # command, exit non-zero. NEVER destroy — teardown stays an explicit choice.
    gate_fail() {
      echo ""
      echo "[setup] FAILED: $*" >&2
      echo "[setup] the VM is still running on purpose — the evidence is on the box:" >&2
      echo "[setup]   ssh ${HOST}" >&2
      echo "[setup]   ssh ${HOST} 'cd app && git status --porcelain'" >&2
      echo "[setup]   ssh ${HOST} 'cd app && set -a && . ./.env && set +a && pi --list-models'" >&2
      echo "[setup] tear it down only when you are done: just sbx lifecycle teardown {{RUN_ID}}" >&2
      exit 1
    }

    # Which roster to gate. When the caller passes none, use the per-sandbox
    # config FILL ships at a fixed absolute path; a MISSING file is a hard failure,
    # never a silent fall back to the repo default (that drift is what this change
    # removes).
    CONFIG={{ quote(CONFIG) }}
    if [ -z "$CONFIG" ]; then
        CONFIG="/home/exedev/sssf_config.yaml"
    fi
    "${SSH[@]}" "test -f $(printf '%q' "$CONFIG")" < /dev/null \
      || gate_fail "roster $CONFIG is missing on ${HOST} — run: just sbx lifecycle fill {{RUN_ID}}"
    echo "[setup] roster: ${CONFIG}"

    # ── 1. provision ─────────────────────────────────────────────────────────
    # Clear the sentinel first: re-running setup on the same VM would otherwise
    # find the PREVIOUS run's sentinel and declare victory before provision ran.
    echo "[setup] 1/3 provisioning (streaming provision.sh output)"
    "${SSH[@]}" 'rm -f /tmp/PROVISION_READY' < /dev/null \
      || gate_fail "cannot reach ${HOST} over ssh"
    # Stream the HOST working-tree provision.sh over ssh stdin and run it with
    # `bash -s`, instead of the copy inside the VM's clone. The gates A–E below
    # are host-side, so the provisioner that runs must be the same version as
    # the gate that checks its work; origin is the engineer's fork and may lag
    # the working tree, so host-streaming is what keeps provisioner and gate in
    # lockstep. PROVISION_REPO_ROOT stays inside the single quotes so $HOME
    # expands on the VM (the clone lives at ~/app); the file redirect replaces
    # the old < /dev/null, which would swallow the script now that the script
    # itself arrives on stdin. Output streams live.
    "${SSH[@]}" 'PROVISION_REPO_ROOT="$HOME/app" bash -s' < sandbox_mount/guest/provision.sh \
      || gate_fail "provision.sh exited non-zero (its last '── step ──' line names the stage)"

    # Provisioner/gate coherence, made visible. The host copy is authoritative —
    # it is what just ran, and gates A–E are host-side — so this comparison only
    # surfaces that the clone (and therefore origin) may lag the working tree.
    # Deliberately OUTSIDE the gate: skew is informational, never a failure, so
    # it prints and continues and never touches gate_fail or the exit status.
    HOST_PROV_SHA=$(sha256sum sandbox_mount/guest/provision.sh | awk '{print $1}')
    CLONE_PROV_SHA=$("${SSH[@]}" 'sha256sum app/sandbox_mount/guest/provision.sh' < /dev/null 2>/dev/null \
      | awk '{print $1}' || true)
    if [ -n "$CLONE_PROV_SHA" ] && [ "$CLONE_PROV_SHA" != "$HOST_PROV_SHA" ]; then
      echo "[setup] WARN: host provisioner ${HOST_PROV_SHA:0:8} differs from the clone copy ${CLONE_PROV_SHA:0:8} — origin may lag the host"
    fi

    # ── 2. sentinel ──────────────────────────────────────────────────────────
    # provision.sh touches /tmp/PROVISION_READY as its literal last line, so on
    # this synchronous path the file is already there and the loop exits on the
    # first probe. The poll is bounded anyway: it is the only completion signal
    # that stays correct if provision is ever backgrounded, and an unbounded
    # wait on a dead box is a hang, not a failure.
    echo "[setup] 2/3 waiting for /tmp/PROVISION_READY (max 60s)"
    ready=0
    for _ in $(seq 1 30); do
      if "${SSH[@]}" 'test -f /tmp/PROVISION_READY' < /dev/null; then ready=1; break; fi
      sleep 2
    done
    [ "$ready" -eq 1 ] || gate_fail "sentinel /tmp/PROVISION_READY never appeared"
    echo "[setup]     sentinel present"

    # ── 3. the gate ──────────────────────────────────────────────────────────
    echo "[setup] 3/3 health gate (5 assertions)"

    # A — git integrity. Content, not existence: an unsynced golden-VM clone
    # produced 5,641 zero-byte files and reported success, and truncation shows
    # up as ' M path'. Expected-vs-actual SHA is compared by prefix so a short
    # commit_sha in the record still matches a full HEAD.
    #
    # Phase 2 splits the two HEADs: factory_sha is the toolbelt clone's HEAD and
    # commit_sha is the TARGET clone's HEAD (the harvest baseline). When the
    # roster's `app:` block names a repo, the target clone must exist and match
    # commit_sha; otherwise (vendored payload) commit_sha is the factory HEAD.
    # Only the FACTORY tree must be clean — a target clone is ignored there, and
    # provision's bun install may legitimately rewrite the target's bun.lock. The
    # configured app.path's untracked-directory entry ('?? <path>/') is filtered
    # out before that assertion: the path is roster DATA, so the gate must treat
    # it as expected content rather than depend on a hand-edited .gitignore.
    echo "[gate] A git integrity"
    A_MODE=""
    if A_OUT=$("${SSH[@]}" 'bash -s' "$SHA" "$FACTORY_SHA" "$CONFIG" <<'REMOTE_A'
    set -uo pipefail
    cd "$HOME/app" || { echo "   no ~/app on this VM — FILL never ran"; exit 1; }
    want="${1:-}"
    factory="${2:-}"
    cfg="${3:-}"

    # Which payload the record points at: the roster's app block decides. awk is
    # fine here — the block is flat — and it mirrors FILL's parse.
    app_repo=""; app_path=""
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
      app_repo=$(awk '/^app:[[:space:]]*$/ {a=1; next} /^[^[:space:]]/ {a=0}
                      a && /^[[:space:]]+repo:[[:space:]]/ {print $2; exit}' "$cfg")
      app_path=$(awk '/^app:[[:space:]]*$/ {a=1; next} /^[^[:space:]]/ {a=0}
                      a && /^[[:space:]]+path:[[:space:]]/ {print $2; exit}' "$cfg")
    fi
    [ -n "$app_repo" ] && [ -z "$app_path" ] && app_path=target

    head="$(git rev-parse HEAD)" || { echo "   git rev-parse failed — .git is damaged"; exit 1; }

    if [ -n "$app_repo" ]; then
      echo "   mode target"
      # factory_sha is the factory clone's own HEAD — the toolbelt that ran the
      # run. A record predating the field reads empty; skip rather than fail.
      if [ -n "$factory" ]; then
        case "$head" in
          "$factory"*) ;;
          *) echo "   factory HEAD $head does not match recorded factory_sha $factory"; exit 1 ;;
        esac
        echo "   factory  ${factory} (matches factory HEAD)"
      fi
      # commit_sha is the TARGET clone's HEAD — the harvest baseline.
      tdir="$HOME/app/$app_path"
      [ -d "$tdir/.git" ] || { echo "   target $app_path is not a git repository — FILL never cloned it"; exit 1; }
      thead="$(git -C "$tdir" rev-parse HEAD)" || { echo "   target $app_path: git rev-parse failed"; exit 1; }
      [ -n "$want" ] || { echo "   record has no commit_sha — FILL never completed"; exit 1; }
      case "$thead" in
        "$want"*) ;;
        *) echo "   target HEAD $thead does not match the recorded commit_sha $want"; exit 1 ;;
      esac
      echo "   target   ${want} (matches target HEAD)"
      # Deliberately NOT asserting a clean target tree: provision's bun install
      # may legitimately rewrite bun.lock. Only the factory clone must be clean.
    else
      echo "   mode vendored"
      if [ -n "$factory" ]; then
        case "$head" in
          "$factory"*) ;;
          *) echo "   factory HEAD $head does not match recorded factory_sha $factory"; exit 1 ;;
        esac
        echo "   factory  ${factory} (matches factory HEAD)"
      fi
      [ -n "$want" ] || { echo "   record has no commit_sha — FILL never completed"; exit 1; }
      case "$head" in
        "$want"*) ;;
        *) echo "   factory HEAD $head does not match the recorded commit_sha $want"; exit 1 ;;
      esac
      echo "   commit_sha ${want} (matches factory HEAD)"
    fi

    # The roster's app.path is DATA, not a .gitignore concern: FILL clones the
    # target app to ~/app/$app_path, so its untracked-directory entry ('?? hello/')
    # is expected. Drop exactly that one whole line; every OTHER porcelain line
    # still fails the gate. Only when app_path is non-empty (it is empty in
    # vendored mode, and an empty pattern must never hide real output).
    porcelain="$(git status --porcelain)"
    if [ -n "$app_path" ]; then
      porcelain="$(printf '%s\n' "$porcelain" | grep -vxF "?? ${app_path}/" || true)"
    fi
    if [ -n "$porcelain" ]; then
      echo "   unexpected working-tree changes in the factory clone (the tree must be clean):"
      printf '%s\n' "$porcelain" | sed 's/^/     /'
      exit 1
    fi
    echo "   factory working tree clean"
    REMOTE_A
    ); then
      printf '%s\n' "$A_OUT"
      A_MODE=$(printf '%s\n' "$A_OUT" | awk '/^   mode /{print $2; exit}')
      echo "[gate] A PASS  git integrity (${A_MODE:-unknown} payload)"
    else
      printf '%s\n' "$A_OUT" >&2
      gate_fail "assertion A — git integrity"
    fi

    # B — pi is current and has models. `pi --list-models` EXITS 0 while
    # printing "No models available", so never trust $?: assert on the output,
    # and reject that exact string, which is otherwise one non-empty line and
    # would sail through a naive non-empty check. Version parity is checked here
    # too: a stale, image-baked pi would otherwise pass every other assertion
    # while the mount's done-condition (pi == registry latest) is false.
    echo "[gate] B pi is current and --list-models is non-empty"
    if "${SSH[@]}" 'bash -s' <<'REMOTE_B'; then
    set -uo pipefail
    # Keys live in app/.env; `ssh host cmd` carries no environment, so a fresh
    # shell's `pi --list-models` lists NOTHING until .env is sourced. Source first.
    set -a; [ -f "$HOME/app/.env" ] && . "$HOME/app/.env"; set +a
    # `command -v` first: without it a missing pi prints one line of
    # "command not found" and a bare non-empty check calls that a pass.
    command -v pi >/dev/null 2>&1 || { echo "   pi is not on PATH"; exit 1; }
    # Version parity with the registry: provision step 4 must have landed the
    # latest. No host expansion here (quoted heredoc), so npm resolves remotely.
    want="$(npm view @earendil-works/pi-coding-agent version)" || { echo "   npm view failed — cannot verify pi currency"; exit 1; }
    got="$(pi --version 2>/dev/null || true)"
    [ "$got" = "$want" ] || { echo "   pi is $got, registry latest is $want — provision step 4 did not land latest"; exit 1; }
    echo "   pi $got matches registry latest"
    out="$(pi --list-models 2>&1 || true)"
    n="$(printf '%s\n' "$out" | grep -c . || true)"
    if [ "${n:-0}" -eq 0 ]; then
      echo "   pi --list-models printed nothing"; exit 1
    fi
    if printf '%s' "$out" | grep -qi 'no models available'; then
      echo "   pi says: No models available — app/.env was not sourced or holds no keys"; exit 1
    fi
    echo "   ${n} lines from pi --list-models"
    REMOTE_B
      echo "[gate] B PASS  pi current and built-in providers loaded from app/.env"
    else
      gate_fail "assertion B — pi stale, missing, or --list-models empty or 'No models available'"
    fi

    # C, D, E run as ONE script inside the sandbox. C pings each roster model
    # THROUGH the sandbox's own pi, D asks pi for a real cost, and E checks that
    # every roster provider has its env key. The gate exercises the sandbox's
    # pi/egress directly; the only credentials it touches are app/.env's.
    echo "[gate] C roster ping   D non-zero cost   E credential coverage"
    if "${SSH[@]}" 'bash -s' {{ quote(CONFIG) }} <<'REMOTE_CDE'; then
    set -uo pipefail
    cd "$HOME/app" || { echo "   no ~/app on this VM"; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "   jq missing (it ships in the exeuntu image)"; exit 1; }
    command -v pi >/dev/null 2>&1 || { echo "   pi is not on PATH"; exit 1; }
    # Keys live in app/.env; every pi call below needs them in the environment.
    set -a; [ -f .env ] && . ./.env; set +a

    # $1 is the CONFIG argument, forwarded over ssh as a positional because the
    # remote shell inherits no environment. The caller may leave it empty.
    CFG="${1:-}"
    [ -n "$CFG" ] || CFG="/home/exedev/sssf_config.yaml"
    [ -f "$CFG" ] || { echo "   missing ${CFG} — run FILL first"; exit 1; }

    # Every `model:` line is `provider/id`, and the provider half is a pi PROVIDER
    # name (deepseek, zai, kimi-coding, minimax-cn, zai-coding-cn). Both halves are
    # exactly what pi --provider/--model want, so nothing is stripped.
    MODELS="$(awk '/^[[:space:]]*model:[[:space:]]/ {print $2}' "$CFG" | sort -u)"
    [ -n "$MODELS" ] || { echo "   parsed zero models out of ${CFG}"; exit 1; }

    # ── C: ping every model in the ACTIVE roster, THROUGH PI ─────────────────
    # pi resolves the provider, reads its api key from the environment, picks the
    # api flavor (openai-completions AND anthropic-messages both appear across
    # providers), and hits the baseUrl — so ONE call verifies credential + baseUrl
    # + api flavor + built-in provider entry, which a single provider curl never
    # could for a direct provider.
    ping_fail=0
    for m in $MODELS; do
      provider="${m%%/*}"; model="${m#*/}"
      resp="$(timeout 180 pi -p --no-tools --provider "$provider" --model "$model" \
                'ping - respond with pong' < /dev/null 2>/dev/null || true)"
      if [ -n "$(printf '%s' "$resp" | tr -d '[:space:]')" ]; then
        echo "   pass  ${m}"
      else
        echo "   FAIL  ${m}: pi returned no output (credential, baseUrl, api flavor, or provider entry)"
        ping_fail=1
      fi
    done

    # ── D: pi actually REPORTS cost ──────────────────────────────────────────
    # The thing being guarded is precise: adw_modules/agent_pi.py reads
    # usage.cost.total straight out of pi. pi's built-in catalog carries the rate
    # table, so a factory that reports $0.0000 forever while genuinely spending is
    # the failure. Observed once: a 463.6k-token run logged $0.0000.
    #
    # Ask pi directly rather than diffing provider key usage (that rounds to $0
    # on a one-sentence call and would false-fail). The live call runs on the
    # roster's defaults.model — the model every agent inherits at minimum.
    DEFAULT_MODEL="$(awk '
      /^defaults:[[:space:]]*$/ { d=1; next }
      /^[^[:space:]]/          { d=0 }
      d && /^[[:space:]]+model:[[:space:]]/ { print $2; exit }
    ' "$CFG")"
    [ -n "$DEFAULT_MODEL" ] || DEFAULT_MODEL="$(printf '%s\n' "$MODELS" | head -n 1)"
    d_provider="${DEFAULT_MODEL%%/*}"; d_model="${DEFAULT_MODEL#*/}"
    cost_fail=0
    # jq, not python: an unindented line inside a recipe body TERMINATES the
    # recipe, and multi-line python cannot survive that. jq ships in the image.
    pi_cost="$(timeout 180 pi -p --mode json \
                 --provider "$d_provider" --model "$d_model" \
                 'Write one sentence about sandboxes.' < /dev/null 2>/dev/null \
               | jq -s '[.. | objects | select(has("cost")) | .cost.total // 0] | max // 0' \
               || echo 0)"
    if awk -v c="$pi_cost" 'BEGIN { exit !(c > 0) }'; then
      echo "   pi reports cost \$${pi_cost} on a live call (built-in rate table loaded)"
    else
      echo "   FAIL  pi reported cost 0 on a live call — every run would log"
      echo "         \$0.0000 while really spending money"
      cost_fail=1
    fi

    # ── E: every roster provider has a credential in the environment ─────────
    # The sandbox pi reads its provider keys from env vars (pi built-ins); FILL
    # wrote them to app/.env and this script sourced that file above. The
    # provider -> env-var map is copied from pi's own getApiKeyEnvVars
    # (pi-ai/dist/env-api-keys.js). setup.just gate E is one of TWO copies; the
    # other is sandbox_mount/host/roster_keys.sh. Keep them in sync.
    key_var_for() {
      case "$1" in
        deepseek)      echo DEEPSEEK_API_KEY ;;
        zai)           echo ZAI_API_KEY ;;
        zai-coding-cn) echo ZAI_CODING_CN_API_KEY ;;
        kimi-coding)   echo KIMI_API_KEY ;;
        minimax)       echo MINIMAX_API_KEY ;;
        minimax-cn)    echo MINIMAX_CN_API_KEY ;;
        openrouter)    echo OPENROUTER_API_KEY ;;
        openai)        echo OPENAI_API_KEY ;;
        anthropic)     echo ANTHROPIC_API_KEY ;;
        google)        echo GEMINI_API_KEY ;;
        mistral)       echo MISTRAL_API_KEY ;;
        xai)           echo XAI_API_KEY ;;
        moonshotai)    echo MOONSHOT_API_KEY ;;
        groq)          echo GROQ_API_KEY ;;
        cerebras)      echo CEREBRAS_API_KEY ;;
        fireworks)     echo FIREWORKS_API_KEY ;;
        together)      echo TOGETHER_API_KEY ;;
        baseten)       echo BASETEN_API_KEY ;;
        *) return 1 ;;
      esac
    }
    cred_fail=0
    PROVIDERS="$(printf '%s\n' "$MODELS" | sed 's|/.*||' | sort -u)"
    for p in $PROVIDERS; do
      if ! var="$(key_var_for "$p")"; then
        echo "   FAIL  provider ${p} is not a known pi built-in — no env-var mapping"
        cred_fail=1
        continue
      fi
      if [ -n "${!var:-}" ]; then
        echo "   credential present for ${p} (${var})"
      else
        echo "   FAIL  provider ${p} needs ${var}, unset in the sourced environment"
        cred_fail=1
      fi
    done

    [ "$ping_fail" -eq 0 ] || exit 2
    [ "$cost_fail" -eq 0 ] || exit 3
    [ "$cred_fail" -eq 0 ] || exit 4
    REMOTE_CDE
      echo "[gate] C PASS  every roster model answered through pi"
      echo "[gate] D PASS  non-zero cost on a live call"
      echo "[gate] E PASS  every roster provider has its env key"
    else
      # Exit code tells which of the three failed; the per-line FAIL output above
      # already named the model or the reading.
      rc=$?
      case "$rc" in
        2) gate_fail "assertion C — at least one roster model did not answer through pi" ;;
        3) gate_fail "assertion D — pi reported no cost on a live call" ;;
        4) gate_fail "assertion E — a roster provider's env key is unset" ;;
        *) gate_fail "assertions C/D/E — the remote gate script exited ${rc} (see output above)" ;;
      esac
    fi

    echo ""
    echo "[setup] GATE PASSED — {{RUN_ID}} is healthy on ${HOST}"
    echo "[setup] next: just sbx lifecycle observe {{RUN_ID}}"
