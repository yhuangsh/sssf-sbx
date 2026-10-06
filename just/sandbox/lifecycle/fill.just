# Phase 2 — FILL. Put the code, the roster, and the sandbox's credentials inside
# the VM.
#
# Imported into the root justfile, so no `set` lines here and no local variables:
# six phase files share one scope and a `repo :=` in each would collide.
#
# ONE shape of secret crosses the wire here: the allowlisted vars the engineer
# set in the host .env, shipped as ENVIRONMENT VARIABLES into app/.env on the VM.
# Two kinds ride it: the LLM keys pi's built-in providers read, and the OPTIONAL
# APP_REPO_GIT_TOKEN that authenticates a PRIVATE app repo. There is no host pi
# state to mirror: every provider the rosters name is a pi BUILT-IN, keyed by
# those env vars, and pi's built-in catalog carries each provider's
# baseUrl/api/cost. The discipline is strict — stdin only, 0600, never echoed.

# clone the factory into the VM, optionally pin a sha, ship the roster + credentials: just sbx lifecycle fill <run-id> [sha]
fill RUN_ID *SHA:
    #!/usr/bin/env bash
    set -euo pipefail

    # Recipes already run from the root justfile's directory; cd makes that true
    # even if just is ever invoked with --justfile from elsewhere.
    cd "{{justfile_directory()}}"
    RR="sandbox_mount/host/run_record.py"

    # FACTORY repo: stays PUBLIC and credential-free — no auth, no GitHub
    # integration, no exe.dev git integration. Source is the engineer's PUBLIC
    # FORK (not upstream disler): it is the one that carries the fix commits, so
    # a fresh VM provisions itself with no push access from the host. Only the
    # TARGET clone (below) can be private, and only via APP_REPO_GIT_TOKEN.
    REPO="https://github.com/yhuangsh/sssf-sbx.git"

    # *SHA is variadic: it interpolates to "" when unpinned, space-joined otherwise.
    # Only the first token is meaningful; extra words are a caller mistake we ignore.
    SHA_ARGS="{{SHA}}"
    PIN="${SHA_ARGS%% *}"

    VM=$("$RR" get {{RUN_ID}} vm_name)
    if [ -z "$VM" ]; then
        echo "fill: run record {{RUN_ID}} has no vm_name — run 'just sbx lifecycle create {{RUN_ID}}' first" >&2
        exit 1
    fi
    HOST="$VM.exe.xyz"   # all *.exe.xyz share one host key; the wildcard known_hosts entry is installed

    # ── the per-app input: which payload this run commits to ──────────────
    # The ACTIVE roster. The root justfile's `config` variable is NOT visible here
    # (this phase file is imported into the `sbx::lifecycle` module, and modules
    # inherit no variables), so read the same env var the root's
    # env_var_or_default reads, with the same fallback. Parsed here, shipped below.
    ROSTER="${SSSF_CONFIG:-adws/adw_sssf_config/sssf.config.yaml}"

    # Phase 2: `app.repo` set means TARGET mode — the payload is its own clone of
    # that public repo at app/<path>, and every ADW commit lands there. Empty
    # means VENDORED mode — the payload lives in the factory clone (Phase 0/1).
    # awk stays for the roster's flat blocks; the manifest (nested) gets the uv
    # PEP-723 probe provision.sh established.
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
    APP_PATH=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    [ -n "$APP_REPO" ] && [ -z "$APP_PATH" ] && APP_PATH=target
    if [ -n "$APP_REPO" ]; then MODE=target; else MODE=vendored; fi

    if [ "$MODE" = target ]; then
        echo "==> fill: $VM — factory clone ${PIN:+(pin $PIN)} + target clone $APP_REPO -> app/$APP_PATH${APP_REF:+ (ref $APP_REF)}"
    else
        echo "==> fill: $VM — factory clone ${PIN:+(pin $PIN)} (vendored payload)"
    fi

    # One remote script over stdin instead of a quoted one-liner: nothing here has
    # to survive two layers of shell quoting. Progress goes to stderr so stdout
    # carries exactly one machine-readable line: "<head_sha> <intended_sha>".
    # The OPTIONAL argument must be LAST. ssh does not pass argv — it joins the
    # args into one string that the remote login shell re-parses, so an empty "$PIN"
    # in the middle collapses to nothing and every argument after it shifts left.
    # MEASURED: with the pin second, an unpinned fill died on `$3: unbound variable`.
    # mode is a REQUIRED positional here so pin can stay last.
    CLONE_OUT=$(ssh "$HOST" bash -s -- "$REPO" "{{RUN_ID}}" "$MODE" "$PIN" <<'REMOTE'
    set -euo pipefail
    repo="$1"; run_id="$2"; mode="$3"; pin="${4:-}"

    if [ -d app/.git ]; then
        # Idempotent re-run (also the golden-VM cp path, where app/ arrives stale).
        echo "app/ already present — fetching" >&2
        git -C app fetch --quiet --tags origin
        if [ -z "$pin" ]; then
            # ff-only: a sandbox that already ran an ADW carries commits that ARE
            # the run's output. Never reset over them; report and keep going.
            if ! { git -C app checkout --quiet main && git -C app merge --ff-only --quiet origin/main; }; then
                echo "WARN: could not fast-forward app/ to origin/main — keeping current HEAD" >&2
            fi
        fi
    else
        rm -rf app   # half-finished clone or a non-repo app/; the VM is disposable, the dir is not state
        git clone --quiet "$repo" app
    fi

    if [ -n "$pin" ]; then
        git -C app checkout --quiet "$pin"
    fi

    # The run branch exists only in VENDORED mode. In target mode the factory
    # clone is the toolbelt and is never committed to inside a sandbox — the run
    # branch lives on the target clone instead (the second script below). A branch
    # nobody commits to is a second source of "where the run is".
    # In vendored mode: created at whatever HEAD already is, so it adds no commit,
    # changes no file, and leaves the tree byte-identical — gate assertion A
    # compares HEAD's sha to the record and does not care what the branch is
    # called. Every commit the ADW makes now lands here instead of on main, which
    # is what lets HARVEST bundle exactly this run's work and nothing else.
    # Existing branch on a re-fill: switch to it, never re-create. Its commits ARE
    # the run's output.
    if [ "$mode" = vendored ]; then
        branch="sbx/$run_id"
        if git -C app rev-parse --verify --quiet "refs/heads/$branch" > /dev/null; then
            git -C app switch --quiet "$branch"
            echo "on existing run branch $branch" >&2
            # Switching back to the run branch UNDOES the `checkout $pin` above — the
            # branch still points where it did, so a re-fill onto a newer pin silently
            # kept the old code and only the gate noticed. Advance the branch itself,
            # ff-only so it can never move backwards over commits the run produced.
            # A pin that is not a descendant is a real conflict: say so, let the gate
            # fail, and leave the run's work alone.
            if [ -n "$pin" ] && ! git -C app merge --ff-only --quiet "$pin"; then
                echo "WARN: $branch cannot fast-forward to $pin — its commits are not on that line" >&2
            fi
        else
            git -C app switch --quiet -c "$branch"
            echo "run branch $branch created" >&2
        fi
    fi

    # Resolve the pin remotely rather than prefix-matching on the host: the pin may
    # be short, a tag or a branch, and only the clone can say what it means.
    intended=""
    if [ -n "$pin" ]; then
        intended=$(git -C app rev-parse --verify --quiet "$pin^{commit}" || true)
    fi
    printf '%s %s\n' "$(git -C app rev-parse HEAD)" "$intended"
    REMOTE
    )

    read -r HEAD_SHA INTENDED <<< "$CLONE_OUT"
    if [ -z "${HEAD_SHA:-}" ]; then
        echo "fill: factory clone produced no HEAD sha on $VM — VM left up for debugging" >&2
        exit 1
    fi

    # GATE FIRST, then record. A failed fill must leave commit_sha untouched: harvest
    # takes it as the baseline for `BASE..HEAD`, so writing the box's current HEAD here
    # would move that baseline PAST the run's own commits and harvest would then report
    # "the run committed nothing" while the commits sat on the branch, unbundled.
    if [ -n "$PIN" ]; then
        if [ -z "${INTENDED:-}" ]; then
            echo "fill: pin '$PIN' does not resolve to a commit in the factory clone — VM left up" >&2
            exit 1
        fi
        if [ "$HEAD_SHA" != "$INTENDED" ]; then
            echo "fill: GATE FAILED — factory HEAD $HEAD_SHA != intended $INTENDED — VM left up" >&2
            echo "      factory_sha left at $("$RR" get {{RUN_ID}} factory_sha) — VM left up" >&2
            exit 1
        fi
        echo "==> fill: factory gate ok — HEAD $HEAD_SHA matches pin $PIN"
    else
        echo "==> fill: factory no pin — HEAD $HEAD_SHA (recorded)"
    fi

    # factory_sha is the factory clone's own HEAD. Phase 0: factory and payload are
    # one clone, so it equals commit_sha by construction. Phase 2 splits them —
    # commit_sha tracks the target clone and this one keeps the toolbelt sha.
    "$RR" set {{RUN_ID}} factory_sha="$HEAD_SHA"

    # ── ship credentials BEFORE the target clone (THE credential path) ─────
    # The target clone below authenticates against a possibly-PRIVATE app repo
    # by reading APP_REPO_GIT_TOKEN out of app/.env, so app/.env must land FIRST.
    # This is THE credential path: allowlisted host-.env vars cross as
    # ENVIRONMENT VARIABLES into app/.env on the VM (0600, stdin only, never
    # echoed). Two kinds ride it: the LLM provider keys the sandbox pi's
    # built-in providers read, and the OPTIONAL app-repo git token. Also serves
    # anything else that reads keys from the environment (the ADW python, SDKs).
    # ALLOWLISTED on purpose: host-only overrides (PI_MODELS_PATH, SSSF_CONFIG,
    # ENGINEER_NAME, PI_PATH) must never leak into the box.
    CRED_ENV_VARS=(
        ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY
        GEMINI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY
        ZAI_CODING_CN_API_KEY MOONSHOT_API_KEY KIMI_API_KEY MINIMAX_API_KEY
        MINIMAX_CN_API_KEY MISTRAL_API_KEY XAI_API_KEY GROQ_API_KEY
        CEREBRAS_API_KEY FIREWORKS_API_KEY TOGETHER_API_KEY BASETEN_API_KEY
        APP_REPO_GIT_TOKEN
    )
    # FAIL FAST, before ANY secret is shipped: every roster provider needs its
    # key present in the host env (dotenv-load already put .env vars there).
    # roster_keys.sh owns the provider -> env-var map; without this check a
    # keyless provider would only surface as a call-time failure inside the box.
    sandbox_mount/host/roster_keys.sh "$ROSTER"

    ENV_CONTENT=""
    SHIPPED=()
    for v in "${CRED_ENV_VARS[@]}"; do
        val="${!v:-}"
        if [ -n "$val" ]; then
            ENV_CONTENT+="$v=$val"$'\n'
            SHIPPED+=("$v")
        fi
    done
    if [ "${#SHIPPED[@]}" -gt 0 ]; then
        printf '%s' "$ENV_CONTENT" \
            | ssh "$HOST" 'umask 077 && cat > "$HOME/app/.env" && chmod 600 "$HOME/app/.env"'
        ENV_STAT=$(ssh "$HOST" 'stat -c "%a %s" "$HOME/app/.env"')
        # NAMES only — a proof line that prints a value defeats the 0600.
        # APP_REPO_GIT_TOKEN appearing in this list is the evidence of shipping.
        echo "==> fill: app/.env (mode/size: $ENV_STAT) — env keys: ${SHIPPED[*]}"
    else
        echo "==> fill: no credential env vars set in .env — skipping app/.env (nothing to ship)"
    fi

    if [ "$MODE" = vendored ]; then
        # Phase 0/1: factory and payload are one clone, so commit_sha is its HEAD.
        "$RR" set {{RUN_ID}} commit_sha="$HEAD_SHA"
        echo "==> fill: vendored payload — commit_sha = factory_sha = $HEAD_SHA"
    else
        # ── the target clone: the payload the run actually commits to ─────────
        # Mirrors the factory clone pattern (idempotent fetch / ff-only / pin),
        # then puts the run branch ON THE TARGET. app_ref is the OPTIONAL argument
        # and MUST stay last for the same ssh-argv reason as the factory script.
        CLONE2_OUT=$(ssh "$HOST" bash -s -- "$APP_REPO" "{{RUN_ID}}" "$APP_PATH" "$APP_REF" <<'REMOTE2'
    set -euo pipefail
    repo="$1"; run_id="$2"; path="$3"; ref="${4:-}"

    # Token, if FILL shipped one, lives ONLY in app/.env (0600). Never echoed:
    # read it into a shell var; auth rides an ephemeral askpass so the stored
    # origin URL stays the clean roster URL. GIT_TERMINAL_PROMPT=0 makes a
    # private repo with no creds FAIL fast instead of hanging on a prompt.
    token=""
    if [ -f "$HOME/app/.env" ]; then
        token=$(grep -m1 '^APP_REPO_GIT_TOKEN=' "$HOME/app/.env" | cut -d= -f2- || true)
    fi
    export GIT_TERMINAL_PROMPT=0
    if [ -n "$token" ]; then
        ASKPASS=$(mktemp)
        chmod 700 "$ASKPASS"
        # Written with printf, not a heredoc: the body must keep just's recipe
        # indentation (a column-0 line would end the recipe), and the shebang
        # must sit at column 1 of the helper for the kernel to honor it. The
        # single-quoted lines keep $HOME and $1 literal for askpass RUN time.
        printf '%s\n' \
            '#!/bin/sh' \
            '# git asks twice: username, then password. A GitHub PAT goes in as' \
            '# the password with any non-empty username; the token is read from' \
            '# app/.env at prompt time so it never sits in this file, in argv,' \
            '# or in the remote URL.' \
            'case "$1" in' \
            '    *sername*) echo "x-access-token" ;;' \
            '    *) grep -m1 "^APP_REPO_GIT_TOKEN=" "$HOME/app/.env" | cut -d= -f2- ;;' \
            'esac' > "$ASKPASS"
        trap 'rm -f "$ASKPASS"' EXIT   # ephemeral: gone on success AND on failure
        export GIT_ASKPASS="$ASKPASS"
    fi

    # A failed network op must NAME itself: set -e would otherwise abort with no
    # hint that the repo is private. Print the repo URL, NEVER the token.
    app_repo_clone_failed() {
        if [ -n "$token" ]; then
            echo "fill: APP_REPO_CLONE_FAILED — target clone of $repo failed WITH APP_REPO_GIT_TOKEN set; check the token's existence, scope (repo read) and expiry — the token is never printed" >&2
        else
            echo "fill: APP_REPO_PRIVATE_NO_TOKEN — target clone of $repo failed; if this repo is private, set APP_REPO_GIT_TOKEN in the host .env and re-run: just sbx lifecycle fill $run_id" >&2
        fi
        exit 1
    }

    dir="app/$path"
    if [ -d "$dir/.git" ]; then
        # Idempotent re-run: fetch, and follow main only when no ref pins us.
        echo "$dir/ already present — fetching" >&2
        if ! git -C "$dir" fetch --quiet --tags origin; then
            app_repo_clone_failed
        fi
        if [ -z "$ref" ]; then
            # ff-only: a target that already ran an ADW carries commits that
            # ARE the run's output. Never reset over them; report and go on.
            if ! { git -C "$dir" checkout --quiet main && git -C "$dir" merge --ff-only --quiet origin/main; }; then
                echo "WARN: could not fast-forward $dir to origin/main — keeping current HEAD" >&2
            fi
        fi
    else
        rm -rf "$dir"   # half-finished clone is not state; the VM is disposable
        if ! git clone --quiet "$repo" "$dir"; then
            app_repo_clone_failed
        fi
    fi

    # NON-PERSISTENCE: with a token in play, the stored origin URL must be the
    # clean roster URL. On a leak, print ONLY the named error — never $url (it
    # would carry the token) and never $token.
    if [ -n "$token" ]; then
        url=$(git -C "$dir" remote get-url origin)
        case "$url" in
            *"$token"*) echo "fill: APP_REPO_TOKEN_LEAK — token present in origin URL of $dir" >&2; exit 1 ;;
        esac
    fi

    if [ -n "$ref" ]; then
        git -C "$dir" checkout --quiet "$ref"
    fi

    # The run branch, ON THE TARGET. Created at whatever HEAD already is, so
    # it adds no commit and leaves the tree byte-identical. Every ADW commit
    # now lands here, which is what lets HARVEST bundle exactly this run.
    # Existing branch on a re-fill: switch to it, never re-create.
    branch="sbx/$run_id"
    if git -C "$dir" rev-parse --verify --quiet "refs/heads/$branch" > /dev/null; then
        git -C "$dir" switch --quiet "$branch"
        echo "on existing run branch $branch" >&2
        # Switching back UNDOES the `checkout $ref` above; advance the branch
        # itself, ff-only so it can never move backwards over the run's work.
        if [ -n "$ref" ] && ! git -C "$dir" merge --ff-only --quiet "$ref"; then
            echo "WARN: $branch cannot fast-forward to $ref — its commits are not on that line" >&2
        fi
    else
        git -C "$dir" switch --quiet -c "$branch"
        echo "run branch $branch created on $dir" >&2
    fi

    # Resolve the ref remotely: it may be short, a tag or a branch.
    intended=""
    if [ -n "$ref" ]; then
        intended=$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" || true)
    fi
    printf '%s %s\n' "$(git -C "$dir" rev-parse HEAD)" "$intended"
    REMOTE2
        )

        read -r TARGET_SHA TARGET_INTENDED <<< "$CLONE2_OUT"
        if [ -z "${TARGET_SHA:-}" ]; then
            echo "fill: target clone produced no HEAD sha on $VM — VM left up for debugging" >&2
            exit 1
        fi

        # TARGET GATE FIRST, then record. commit_sha is HARVEST's baseline, so a
        # failed target gate must leave it untouched — same discipline as above.
        if [ -n "$APP_REF" ]; then
            if [ -z "${TARGET_INTENDED:-}" ]; then
                echo "fill: target ref '$APP_REF' does not resolve to a commit — VM left up" >&2
                exit 1
            fi
            if [ "$TARGET_SHA" != "$TARGET_INTENDED" ]; then
                echo "fill: TARGET GATE FAILED — HEAD $TARGET_SHA != intended $TARGET_INTENDED — VM left up" >&2
                echo "      commit_sha left at $("$RR" get {{RUN_ID}} commit_sha) — harvest baseline intact" >&2
                exit 1
            fi
            echo "==> fill: target gate ok — HEAD $TARGET_SHA matches ref $APP_REF"
        else
            echo "==> fill: target no ref — HEAD $TARGET_SHA (recorded)"
        fi

        # commit_sha is what makes N runs comparable, so record the sha that is
        # actually checked out on the target, never the one that was asked for.
        "$RR" set {{RUN_ID}} commit_sha="$TARGET_SHA"
        echo "==> fill: target payload — commit_sha $TARGET_SHA (factory_sha $HEAD_SHA)"
    fi

    # ── ship the roster + a derived settings.json ────────────────────────────
    # No host pi state is mirrored any more: every provider the rosters name is a
    # pi BUILT-IN, keyed by an env var. The sandbox pi learns its model set from
    # the roster it is handed and its credentials from app/.env (shipped earlier,
    # before the target clone); pi's built-in catalog carries baseUrl/api/cost.
    #
    # The base roster is the ACTIVE one — resolved near the top of this recipe
    # (see the `app:` block parse) and shipped verbatim below.

    # Ship the roster VERBATIM: no model rewriting, no host-catalog validation —
    # the setup gate validates against the sandbox's own pi. Fixed ABSOLUTE path,
    # never $HOME: execute/setup build remote command strings through two quoting
    # hops where $HOME expansion is fragile. observe.just already establishes the
    # exeuntu user is `exedev`. Holds no secrets -> 0644.
    cat "$ROSTER" | ssh "$HOST" 'cat > /home/exedev/sssf_config.yaml && chmod 644 /home/exedev/sssf_config.yaml'

    # A derived settings.json so a bare `pi -p` (the `run agent` lane) lands on
    # the roster's default provider/model/thinking. Parse the same `defaults`
    # block setup gate D reads.
    DEFAULT_MODEL=$(awk '
      /^defaults:[[:space:]]*$/ { d=1; next }
      /^[^[:space:]]/          { d=0 }
      d && /^[[:space:]]+model:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    DEFAULT_THINKING=$(awk '
      /^defaults:[[:space:]]*$/ { d=1; next }
      /^[^[:space:]]/          { d=0 }
      d && /^[[:space:]]+thinking:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    DP="${DEFAULT_MODEL%%/*}"; DM="${DEFAULT_MODEL#*/}"
    printf '{\n  "defaultProvider": "%s",\n  "defaultModel": "%s",\n  "defaultThinkingLevel": "%s"\n}\n' \
        "$DP" "$DM" "${DEFAULT_THINKING:-medium}" \
        | ssh "$HOST" 'mkdir -p "$HOME/.pi/agent" && umask 077 && cat > "$HOME/.pi/agent/settings.json" && chmod 600 "$HOME/.pi/agent/settings.json"'

    # Remove stale mirror artifacts so a re-fill of a VM that once got the old
    # mirror converges: an old models.json would shadow pi's built-in catalog
    # with stale keys. auth.json is left alone if present (pi tolerates it;
    # nothing we ship writes it).
    ssh "$HOST" 'rm -f "$HOME/.pi/agent/models.json" "$HOME/.pi/agent/models-store.json"'

    # Prove each landed (mode/size) without printing any content. Single-quoted
    # remote paths so $HOME expands on the VM, not here.
    SE_STAT=$(ssh "$HOST" 'stat -c "%a %s" "$HOME/.pi/agent/settings.json"')
    CF_STAT=$(ssh "$HOST" 'stat -c "%a %s" /home/exedev/sssf_config.yaml')
    echo "==> fill: ~/.pi/agent/settings.json (mode/size: $SE_STAT)"
    echo "==> fill: /home/exedev/sssf_config.yaml (mode/size: $CF_STAT) — shipped verbatim"
