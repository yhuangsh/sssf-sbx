# HARVEST. Pull a run's commits back to the host, then integrate them.
#
# Imported into the root justfile, so no `set` lines here and no local variables:
# the phase files share one scope and a duplicate name across them is a hard error.
#
# TWO INTEGRATION MODES. The most frequent multi-sandbox use is parallel
# ORTHOGONAL features on one repo that merge back into the trunk, so the DEFAULT
# is MERGE: fetch the run branch into the app's LOCAL CLONE (roster
# `app.local_path`), merge it into `base_ref`, verify, report the merge sha.
# COMPETITION (fan-out / best-of-N) is the special case: the arms are
# alternatives, not complements, so `--no-merge` keeps today's bundle-only
# behavior and `just sbx manage compare` ranks them side by side.
#
# WHY A BUNDLE AND NOT A PUSH. The sandbox is filled by a public, unauthenticated
# `git clone` and holds no git credential of any kind — no PAT, no deploy key, no
# ssh identity. That is deliberate: the box runs an autonomous agent under
# --dangerously-skip-permissions, and a push credential would give that agent
# write access to the repo it was cloned from.
# A bundle moves commits across that gap with no credential at all, and the work
# lands in refs you inspect before anything touches a branch of yours.
#
# WHY A RANGE AND NOT --all. `git bundle create f --all` packs the entire history;
# `f <base>..<branch>` packs only the objects the run introduced — KB, not MB. The
# more useful half is the prerequisite: a ranged bundle records "you must already
# have <base>", and `git fetch` REFUSES it otherwise. So a run branch that somehow
# does not descend from the sha FILL pinned is caught here instead of importing
# disconnected history. Free integrity check on the return trip.
#
# NOT A SEVENTH PHASE. The bundle/verify/fetch half never writes the run record —
# the bundle's existence at .sandbox/runs/<id>.bundle IS that record, keeping the
# return trip's integrity state out of the schema. The MERGE half DOES extend the
# record (harvest_state / merge_sha) — the sanctioned field-extension path — so a
# run's integration outcome survives the process; the schema stays closed.
#
# IDEMPOTENT: re-running overwrites the bundle and force-updates the ref. A
# re-harvest after a successful merge sees "Already up to date" and re-reports the
# recorded merge sha. The bundle half only ever writes refs under refs/sandbox/ —
# never your working tree, index, or any branch you own.
#
# POWER PUSH STAYS HUMAN. The merge lands in the local clone only. There is no
# `git push` in this recipe and there never will be: a human reviews the merged
# tree and pushes when ready.

# pull a run's commits home and merge them: just sbx manage harvest <run-id> [--no-merge]
harvest RUN_ID *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"

    RR="sandbox_mount/host/run_record.py"
    RUN_ID="{{ RUN_ID }}"
    BUNDLE=".sandbox/runs/$RUN_ID.bundle"
    # Absolute twin of $BUNDLE for the `git -C <cache>` calls below: `-C` changes
    # git's working directory, so a relative bundle path would resolve against the
    # cache, not the repo root. `cd "{{ justfile_directory() }}"` above fixes $PWD.
    BUNDLE_ABS="$PWD/$BUNDLE"
    BRANCH="sbx/$RUN_ID"
    DEST="refs/sandbox/$RUN_ID"
    HARVEST_REF="refs/harvest/$RUN_ID"
    # Same options teardown uses: BatchMode so this never sits at a prompt,
    # timeouts so it never hangs on a half-dead VM.
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

    # Flags through a variable, not straight into `for ... in`: an empty variadic
    # interpolated into the list is a syntax error, via a variable it is zero
    # iterations. Same idiom as teardown's --no-harvest.
    RAW_FLAGS="{{ FLAGS }}"
    NO_MERGE=0
    for a in $RAW_FLAGS; do
        case "$a" in
            --no-merge) NO_MERGE=1 ;;
            *) echo "harvest: unknown flag $a (only --no-merge)"; exit 2 ;;
        esac
    done

    "$RR" get "$RUN_ID" > /dev/null || { echo "!! harvest: no run record for $RUN_ID"; exit 1; }
    VM=$("$RR" get "$RUN_ID" vm_name)
    BASE=$("$RR" get "$RUN_ID" commit_sha)

    # Which repo the run committed to: the roster's app block decides (same awk
    # as FILL). `app.repo` set means target mode — the branch lives on the target
    # clone at app/<path> and the base commit is NOT in the factory repo; empty
    # means vendored mode, today's `cd app`. SSSF_CONFIG is REQUIRED (shared guard,
    # THE named error) — the app block it names picks the bundle's repo.
    ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
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
    APP_LOCAL=$(awk '
      /^app:[[:space:]]*$/      { a=1; next }
      /^[^[:space:]]/           { a=0 }
      a && /^[[:space:]]+local_path:[[:space:]]/ { print $2; exit }
    ' "$ROSTER")
    # `~` in the roster is the engineer's home; expand it before git sees it.
    APP_LOCAL="${APP_LOCAL/#\~/$HOME}"
    [ -n "$APP_REPO" ] && [ -z "$APP_PATH" ] && APP_PATH=target
    if [ -n "$APP_REPO" ]; then REPO_DIR="app/$APP_PATH"; else REPO_DIR="app"; fi

    # Both of these are "nothing to do", not failures — teardown calls this on runs
    # that died anywhere, and a missing piece is the normal path.
    [ -n "$VM" ]   || { echo "   harvest: no vm_name in the record — nothing to harvest"; exit 0; }
    [ -n "$BASE" ] || { echo "   harvest: no commit_sha in the record — FILL never completed"; exit 0; }

    # Progress goes to stderr so stdout carries exactly one machine-readable line.
    OUT=$(ssh "${SSH_OPTS[@]}" "$VM".exe.xyz bash -s -- "$BASE" "$BRANCH" "$REPO_DIR" <<'REMOTE'
    set -euo pipefail
    base="$1"; branch="$2"; repo_dir="$3"

    cd "$repo_dir" 2> /dev/null || { echo "NOREPO"; exit 0; }
    git rev-parse --git-dir > /dev/null 2>&1 || { echo "NOREPO"; exit 0; }

    # A run filled before run branches existed committed straight onto main. Give it
    # the branch at HEAD: `git branch` creates a ref and nothing else, so this does
    # not switch, does not touch the tree, and is safe on a box mid-run.
    git rev-parse --verify --quiet "refs/heads/$branch" > /dev/null || git branch "$branch" >&2

    tip=$(git rev-parse "refs/heads/$branch")
    if [ "$tip" = "$base" ]; then echo "NOCOMMITS"; exit 0; fi

    # An empty range is the only expected failure and it is handled above, so a
    # failure here is real: report it rather than shipping a truncated bundle.
    git bundle create /tmp/harvest.bundle "$base..refs/heads/$branch" >&2 || { echo "BUNDLEFAIL"; exit 0; }
    printf 'OK %s %s\n' "$tip" "$(git rev-list --count "$base..refs/heads/$branch")"
    REMOTE
    ) || { echo "!! harvest: could not reach $VM over ssh — VM left alone"; exit 1; }

    case "$OUT" in
        NOREPO*)     echo "   harvest: no $REPO_DIR/ repo on $VM — nothing to harvest"; exit 0 ;;
        NOCOMMITS*)  echo "   harvest: $BRANCH is still at $BASE — the run committed nothing"; exit 0 ;;
        BUNDLEFAIL*) echo "!! harvest: git bundle failed on $VM — VM left alone"; exit 1 ;;
        OK\ *)       ;;
        *)           echo "!! harvest: unexpected reply from $VM: $OUT"; exit 1 ;;
    esac
    read -r _ TIP COUNT <<< "$OUT"

    mkdir -p .sandbox/runs
    scp "${SSH_OPTS[@]}" -q "$VM".exe.xyz:/tmp/harvest.bundle "$BUNDLE" \
        || { echo "!! harvest: could not copy the bundle off $VM — VM left alone"; exit 1; }

    # Manual-resolution commands, printed on any path where the merge does not
    # land. They are the same three steps the recipe automates, and they work
    # because the fetch already put the run branch in the clone.
    print_manual_merge() {
        local local_clone="$1" cache_abs="$2" base_ref="$3"
        echo "     manual merge (run branch is fetched; nothing is pushed):"
        echo "       git -C $local_clone fetch $cache_abs refs/sandbox/$RUN_ID:$HARVEST_REF"
        echo "       git -C $local_clone checkout $base_ref"
        echo "       git -C $local_clone merge $HARVEST_REF"
        echo "       # resolve, then: git -C $local_clone add <files> && git -C $local_clone commit"
    }

    if [ -n "$APP_REPO" ]; then
        # TARGET mode: the run's base commit is in the APP repo, not the factory
        # repo, and the app commits must never be fetched into the factory repo.
        # Verify/fetch into a dedicated bare cache of the app repo instead; a
        # public clone, so unauthenticated.
        CACHE=".sandbox/repos/$(basename "$APP_REPO" .git).git"
        CACHE_ABS="$PWD/$CACHE"
        mkdir -p .sandbox/repos
        if [ -d "$CACHE" ]; then
            git -C "$CACHE" fetch --quiet --tags origin \
                || { echo "!! harvest: could not refresh $CACHE — VM left alone"; exit 1; }
        else
            git clone --bare --quiet "$APP_REPO" "$CACHE" \
                || { echo "!! harvest: could not clone $APP_REPO into $CACHE"; exit 1; }
        fi
        # Verify BEFORE fetching: a bundle whose base the cache does not have
        # fails loudly rather than importing disconnected history.
        if ! git -C "$CACHE" bundle verify "$BUNDLE_ABS" > /dev/null 2>&1; then
            echo "!! harvest: $BUNDLE failed verification against $CACHE — this host may not have $BASE"
            git -C "$CACHE" bundle verify "$BUNDLE_ABS" || true
            echo "!! the bundle is kept at $BUNDLE for inspection. VM left alone."
            exit 1
        fi
        # --force so a re-harvest of a run that committed more since last time
        # updates the ref instead of refusing a non-fast-forward.
        git -C "$CACHE" fetch --force --quiet "$BUNDLE_ABS" "refs/heads/$BRANCH:$DEST" \
            || { echo "!! harvest: fetch into $DEST failed — bundle kept at $BUNDLE"; exit 1; }

        echo "   harvest: $COUNT commit(s) -> $CACHE $DEST"
        echo "     bundle:  $BUNDLE"
        echo "     read it: git -C $CACHE log --oneline --graph $BASE..$DEST"
        echo "     diff it: git -C $CACHE diff $BASE..$DEST"

        # ── mode selection ───────────────────────────────────────────────────
        # The bundle is home and verified in BOTH modes; that half is the record
        # of the run's work. `--no-merge` then stops here (competing arms have
        # nothing to merge — they are alternatives). The default continues into
        # the local clone.
        if [ "$NO_MERGE" = 1 ]; then
            "$RR" set "$RUN_ID" harvest_state=bundle-only > /dev/null
            uv run sandbox_mount/host/issue_tracker.py harvest "$RUN_ID" \
                --result bundle-only \
                || echo "   issues: harvest comment failed (best-effort)"
            echo "   harvest: --no-merge — bundle-only, no merge attempted"
            exit 0
        fi

        BASE_REF=$("$RR" get "$RUN_ID" base_ref)
        [ -n "$BASE_REF" ] || BASE_REF=main

        # No local clone to merge into: NAMED FALLBACK, not an error. The bundle
        # is the deliverable and merge is a convenience; the manual commands are
        # exact. Record bundle-only so the tracker reports the real state.
        if [ -z "$APP_LOCAL" ]; then
            echo "   harvest: no app.local_path in roster — bundle-only"
            print_manual_merge "<your app clone>" "$CACHE_ABS" "$BASE_REF"
            "$RR" set "$RUN_ID" harvest_state=bundle-only > /dev/null
            uv run sandbox_mount/host/issue_tracker.py harvest "$RUN_ID" \
                --result bundle-only \
                || echo "   issues: harvest comment failed (best-effort)"
            exit 0
        fi

        # A named abort (not a fallback): the roster NAMES a clone; if it is not a
        # repo there, merging into whatever is at that path would be wrong. Bundle
        # stays, VM stays.
        if [ ! -d "$APP_LOCAL" ] || ! git -C "$APP_LOCAL" rev-parse --git-dir > /dev/null 2>&1; then
            echo "!! harvest: app.local_path '$APP_LOCAL' is not a git repo — bundle-only, no merge"
            print_manual_merge "$APP_LOCAL" "$CACHE_ABS" "$BASE_REF"
            exit 1
        fi

        # MERGE ONLY INTO A CLEAN TREE. An in-progress edit in the local clone
        # would be entangled with the merge and a later revert would destroy it.
        # Nothing has been touched in the clone yet, so this is a pure abort.
        if [ -n "$(git -C "$APP_LOCAL" status --porcelain)" ]; then
            echo "!! harvest: local clone at $APP_LOCAL has uncommitted changes — clean it or use --no-merge"
            echo "     (nothing was changed in the clone; the bundle is at $BUNDLE)"
            exit 1
        fi

        # Fetch the run branch INTO the local clone so the manual commands work and
        # the branch survives a conflict abort.
        git -C "$APP_LOCAL" fetch --force --quiet "$CACHE_ABS" "refs/sandbox/$RUN_ID:$HARVEST_REF" \
            || { echo "!! harvest: could not fetch $HARVEST_REF into $APP_LOCAL — bundle-only"; exit 1; }

        if ! git -C "$APP_LOCAL" rev-parse --verify --quiet "$BASE_REF^{commit}" > /dev/null; then
            echo "!! harvest: base_ref '$BASE_REF' does not exist in $APP_LOCAL — bundle-only, no merge"
            print_manual_merge "$APP_LOCAL" "$CACHE_ABS" "$BASE_REF"
            exit 1
        fi

        git -C "$APP_LOCAL" checkout --quiet "$BASE_REF"
        # PRE is base_ref's tip BEFORE the merge — the exact revert anchor for a
        # fast-forward OR a true merge (captured after the checkout so it is
        # correct even if the clone was parked on another branch). RECORDED_SHA
        # is the sha a PREVIOUS harvest already recorded, re-reported unchanged
        # when a re-harvest lands "Already up to date".
        PRE=$(git -C "$APP_LOCAL" rev-parse HEAD)
        RECORDED_SHA=$("$RR" get "$RUN_ID" merge_sha)

        ALREADY_MERGED=0
        # MERGE. Fast-forward or true merge, one or the other. A failure is almost
        # always a conflict, and a conflict is a NAMED ABORT: we report the files,
        # both sides, and the exact commands, then put the tree back.
        if git -C "$APP_LOCAL" merge --no-edit "$HARVEST_REF" > /tmp/harvest-merge.log 2>&1; then
            MERGE_SHA=$(git -C "$APP_LOCAL" rev-parse HEAD)
            # HEAD unmoved means the run branch was already merged (git prints
            # "Already up to date" and exits 0). If the record already carries a
            # merge sha, keep it: sibling merges move the clone tip, so
            # rev-parse HEAD is NOT this run's merge sha any more.
            if [ "$MERGE_SHA" = "$PRE" ] && [ -n "$RECORDED_SHA" ]; then
                MERGE_SHA="$RECORDED_SHA"
                ALREADY_MERGED=1
            fi
        else
            CONFLICT_FILES=$(git -C "$APP_LOCAL" diff --name-only --diff-filter=U | tr '\n' ' ')
            if ! git -C "$APP_LOCAL" merge --abort 2> /dev/null; then
                git -C "$APP_LOCAL" reset --hard "$PRE" > /dev/null 2>&1 || true
            fi
            echo "!! harvest: CONFLICT merging $HARVEST_REF into $BASE_REF — merge aborted, clone clean"
            echo "     conflicting files: ${CONFLICT_FILES:-<none reported>}"
            echo "     run branch side (${BASE_REF}..$HARVEST_REF):"
            git -C "$APP_LOCAL" log --oneline "$BASE_REF..$HARVEST_REF" | sed 's/^/       /'
            echo "     base side (current $BASE_REF tip): $(git -C "$APP_LOCAL" rev-parse --short HEAD)"
            print_manual_merge "$APP_LOCAL" "$CACHE_ABS" "$BASE_REF"
            "$RR" set "$RUN_ID" harvest_state=harvested-unmerged > /dev/null
            uv run sandbox_mount/host/issue_tracker.py harvest "$RUN_ID" \
                --result unmerged --base-ref "$BASE_REF" --conflicts "$CONFLICT_FILES" \
                || echo "   issues: harvest comment failed (best-effort)"
            exit 1
        fi

        # A re-harvest of an already-merged run is a true no-op: nothing moved,
        # the record already carries the merge sha. Re-report it and stop — do
        # NOT rewrite merge_sha (it would drift to the moved clone tip) and do
        # not post a second 'merged' comment for the same landing.
        if [ "$ALREADY_MERGED" = 1 ]; then
            echo "   harvest: already merged $HARVEST_REF into $BASE_REF in $APP_LOCAL"
            echo "     merge sha: $MERGE_SHA (recorded)"
            echo "     merge is local only — push it yourself when ready"
            exit 0
        fi

        # ── post-merge verification (best-effort) ────────────────────────────
        # Re-run the manifest's checks against the MERGED tree. Missing runtime is
        # a skip, not a failure (the runner says so and exits 0). Only a real
        # check failure reverts.
        CHECKS_OUT=$(uv run sandbox_mount/host/run_manifest_checks.py "$APP_LOCAL" \
            --manifest "$APP_MANIFEST" 2>&1) && CHECKS_RC=0 || CHECKS_RC=$?
        printf '%s\n' "$CHECKS_OUT"
        if printf '%s' "$CHECKS_OUT" | grep -q 'executed=0'; then
            echo "post-merge checks skipped: runtime not available host-side"
        fi
        if [ "$CHECKS_RC" != 0 ]; then
            FAILING=$(printf '%s\n' "$CHECKS_OUT" | awk '/^FAIL /{print $2}' | tr '\n' ' ')
            # Revert to PRE: covers both a fast-forward and a true merge, and the
            # tree was clean before we started, so nothing of the human's is lost.
            git -C "$APP_LOCAL" reset --hard "$PRE" > /dev/null
            echo "!! harvest: post-merge checks FAILED — merge reverted (clone back at $(git -C "$APP_LOCAL" rev-parse --short HEAD))"
            echo "   the run branch stays fetched at $HARVEST_REF; re-apply with:"
            echo "     git -C $APP_LOCAL merge $HARVEST_REF"
            "$RR" set "$RUN_ID" harvest_state=merge-broke-build merge_sha="$MERGE_SHA" > /dev/null
            uv run sandbox_mount/host/issue_tracker.py harvest "$RUN_ID" \
                --result broke-build --base-ref "$BASE_REF" --merge-sha "$MERGE_SHA" \
                --failing-checks "$FAILING" \
                || echo "   issues: harvest comment failed (best-effort)"
            exit 1
        fi

        "$RR" set "$RUN_ID" harvest_state=merged merge_sha="$MERGE_SHA" > /dev/null
        uv run sandbox_mount/host/issue_tracker.py harvest "$RUN_ID" \
            --result merged --base-ref "$BASE_REF" --merge-sha "$MERGE_SHA" \
            || echo "   issues: harvest comment failed (best-effort)"
        echo "   harvest: merged $HARVEST_REF into $BASE_REF in $APP_LOCAL"
        echo "     merge sha: $MERGE_SHA"
        echo "     merge is local only — push it yourself when ready"
    else
        # Verify BEFORE fetching. This is where a bundle whose base the host does
        # not have fails, and it fails loudly rather than importing something
        # detached.
        if ! git bundle verify "$BUNDLE" > /dev/null 2>&1; then
            echo "!! harvest: $BUNDLE failed verification — this host may not have $BASE"
            git bundle verify "$BUNDLE" || true
            echo "!! the bundle is kept at $BUNDLE for inspection. VM left alone."
            exit 1
        fi

        # --force so a re-harvest of a run that committed more since last time
        # updates the ref instead of refusing a non-fast-forward.
        git fetch --force --quiet "$BUNDLE" "refs/heads/$BRANCH:$DEST" \
            || { echo "!! harvest: fetch into $DEST failed — bundle kept at $BUNDLE"; exit 1; }

        echo "   harvest: $COUNT commit(s) -> $DEST"
        echo "     bundle:  $BUNDLE"
        echo "     read it: git log --oneline --graph $BASE..$DEST"
        echo "     diff it: git diff $BASE..$DEST"
        # Vendored mode: the factory clone IS the payload, so there is no separate
        # app clone to merge into. Record the mode explicitly and stop.
        "$RR" set "$RUN_ID" harvest_state=bundle-only > /dev/null
    fi
