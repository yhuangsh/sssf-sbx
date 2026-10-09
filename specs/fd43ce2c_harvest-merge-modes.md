# Harvest Integration Modes — merge-into-trunk default, bundle-only for competing runs

## Goal

`just sbx manage harvest` grows two integration modes:

- **MERGE (default)** — for parallel-orthogonal features: fetch the run branch into the app's
  **local clone** (roster `app.local_path`), merge it into `base_ref`, run the manifest's checks
  against the merged tree, report the merge sha. Never push.
- **BUNDLE-ONLY (`--no-merge`)** — today's exact behavior, for competing runs (fan-out/best-of-N).

Plus a read-only `just sbx manage compare <id1> <id2> ...` recipe, issue-tracker close-comment
extensions, and cookbook/SKILL updates.

## Current state (verified by reading)

- `just/sandbox/manage/harvest.just` — bundle-only today. Target mode (roster `app.repo` set)
  fetches the bundle into a bare cache `.sandbox/repos/<app>.git` at `refs/sandbox/<run_id>`;
  vendored mode fetches into the factory repo. Writes nothing to the run record.
- `sandbox_mount/host/run_record.py` — closed schema (`FIELDS` tuple); sanctioned extension is to
  add fields to `FIELDS` (pattern documented in the issue-tracker comment block).
  `commit_sha` is already the run's base sha (FILL records it as harvest's baseline).
- `just/sandbox/lifecycle/fill.just` — sets `commit_sha` at ~line 260 (vendored) and ~399 (target);
  roster `app:` block parsed with the same awk idiom everywhere; roster has `app.ref` (default
  `main`).
- `just/sandbox/lifecycle/teardown.just` — calls `just sbx manage harvest "$RUN_ID"` and ABORTS
  before destroy on harvest failure; `--no-harvest` flag pattern (`*FLAGS` variadic) is the model
  for harvest's `--no-merge`.
- `sandbox_mount/host/issue_tracker.py` — PEP-723 uv script wrapping `gh`; best-effort (failures
  warn, exit 0); has `_app_config()` returning `(repo, path, local_path)`; labels dict at top;
  `close_issue()` is idempotent; `_harvest_status()` renders the bundle line in the final comment.
- `adws/adw_modules/quality.py` `_load_checks` — manifest `checks:` has TWO shapes: MAP
  (`{test: [bun, test, server.test.ts]}` — hello-server's shape) and LIST of
  `{name, area, operation, argv, timeout_seconds}`. Defaults: area=backend, operation=build,
  timeout=120. argv paths relative to the app dir.
- hello-server (https://github.com/yhuangsh/hello-server, PUBLIC, HEAD 8833191…) — `server.ts`
  (~10 lines, `greet()` + `Bun.serve`), `server.test.ts`, `sssf.app.yaml` with map-form checks,
  runtime bun, port 4501.
- Roster `adws/adw_sssf_config/sssf.hello.config.yaml` — `app.local_path` documented but commented
  out. Verification uses a SCRATCH roster under /tmp that sets it.
- `just/sandbox/manage/mod.just` — imports list/harvest/sync_issues; header comment claims harvest
  "never [writes] the run record" — that becomes false and must be updated.
- SKILL.md harvest mentions: line 3 (keywords), ~126, ~157 (recipe table).

## Files to change

### 1. `sandbox_mount/host/run_record.py` — schema extension

Add to `FIELDS` (with a comment block in the style of the issue-tracker one):

- `base_ref` — branch the run started from (e.g. `main`); from roster `app.ref`.
- `base_sha` — the sha `base_ref` pointed at when the run filled. (Duplicates `commit_sha` today;
  record both — `commit_sha` stays harvest's bundle baseline, `base_sha` is the merge anchor.)
- `merge_mode` — `merge` (default) | `bundle-only`. Seed `"merge"` in `create()` so old and new
  records default alike.
- `harvest_state` — null | `bundle-only` | `merged` | `harvested-unmerged` | `merge-broke-build`.
- `merge_sha` — the merge commit (or fast-forward tip) sha in the local clone.

No coercion entries needed (all strings). Update the module docstring's field list comment if it
enumerates fields.

### 2. `just/sandbox/lifecycle/fill.just` — record base_ref / base_sha

In the TARGET-mode branch (near line 399, where `commit_sha="$TARGET_SHA"` is set): parse
`app.ref` from the roster with the same awk idiom (default `main` when empty), then
`"$RR" set {{RUN_ID}} base_ref="$APP_REF" base_sha="$TARGET_SHA"`. In the vendored branch
(~line 260): set `merge_mode=bundle-only` explicitly (merge mode is a target-mode feature; the
factory clone is never a merge target). Leave `base_ref`/`base_sha` empty in vendored mode.
GATE-FIRST ordering is load-bearing — set these only where `commit_sha` is set today, never earlier.

### 3. `sandbox_mount/host/run_manifest_checks.py` — NEW host-side check runner

PEP-723 uv script (pyyaml only), mirroring `issue_tracker.py`'s header. Usage:

```
run_manifest_checks.py <app_dir> [--manifest sssf.app.yaml]
```

- Load `<app_dir>/<manifest>`; no file or no `checks:` → print a named skip line, exit 0.
- Accept BOTH check shapes (map and list) exactly like `quality._load_checks` (map entries get
  name+argv; defaults timeout 120). No `{outdir}` handling needed — hello's checks don't use it;
  if `{outdir}` appears in an argv entry, substitute a mktemp -d path and note it.
- For each check: if `argv[0]` is not on PATH (`shutil.which`) → print
  `SKIP <name>: runtime '<argv0>' not available host-side` and continue (skip is not failure).
- Run with `cwd=app_dir`, `subprocess.run`, timeout; stream captured output to a
  `<app_dir>/.harvest-checks/<name>.log` (or /tmp — never into the kernel repo).
- Exit 0 if every executed check passed; exit 1 with the failing check names + log paths otherwise.

### 4. `just/sandbox/manage/harvest.just` — the two modes

Change signature to `harvest RUN_ID *FLAGS` and parse `--no-merge` exactly like teardown's
`--no-harvest` (unknown flag → exit 2). Keep the ENTIRE existing bundle/verify/fetch flow
unchanged — it runs first in both modes and stays the record of the work. After the fetch
succeeds (target mode only — vendored keeps today's ending unchanged):

**Mode selection:** `--no-merge` → stop after the bundle fetch (today's behavior, plus
`"$RR" set "$RUN_ID" harvest_state=bundle-only` and an issue_tracker `harvest --result bundle-only`
call; see §6). Default (merge mode) continues below. Recorded `merge_mode` on the record is
informational; the flag decides at call time.

**MERGE path (default, target mode, after the cache fetch):**

1. Resolve `app.local_path` from the roster (same awk idiom; expand `~`). Absent/empty → NAMED
   FALLBACK, not an error: print `harvest: no app.local_path in roster — bundle-only` plus exact
   manual merge instructions (the cache path, the ref, the `git fetch`/`git merge` commands),
   set `harvest_state=bundle-only`, exit 0.
2. `local_path` must exist and be a git repo (`git -C ... rev-parse --git-dir`) → else named abort
   (exit 1) with the manual instructions; bundle stays.
3. Require a CLEAN tree: `git -C "$LOCAL" status --porcelain` empty → else NAMED ABORT
   (`harvest: local clone at $LOCAL has uncommitted changes — clean it or use --no-merge`), exit 1.
   Nothing has been touched in the local clone at this point.
4. Fetch the run branch: `git -C "$LOCAL" fetch --force "$CACHE_ABS" "refs/sandbox/$RUN_ID:refs/harvest/$RUN_ID"`.
   (`$CACHE_ABS` = absolute path of `.sandbox/repos/<app>.git` — same `$PWD` trick as `$BUNDLE_ABS`.)
5. Record `PRE=$(git -C "$LOCAL" rev-parse HEAD)`; checkout `base_ref` (from the run record;
   default `main` if empty). If `base_ref` doesn't exist in the local clone → named abort.
6. `git -C "$LOCAL" merge --no-edit "refs/harvest/$RUN_ID"` — allow fast-forward or true merge.
   - SUCCESS → capture `MERGE_SHA=$(git rev-parse HEAD)`; go to post-merge verification (7).
   - CONFLICT (merge exits nonzero) → BEFORE aborting capture conflicting files via
     `git -C "$LOCAL" diff --name-only --diff-filter=U`; then `git -C "$LOCAL" merge --abort`
     (fall back to `git reset --hard "$PRE"` if abort fails). Print a conflict report: the
     conflicting file list, both sides (`git log --oneline "$base_ref..refs/harvest/$RUN_ID"` and
     the base side), and EXACT manual-resolution commands (the fetch already happened, so:
     `git -C $LOCAL checkout $base_ref && git -C $LOCAL merge refs/harvest/$RUN_ID`, resolve,
     `git add`, `git commit`). `"$RR" set "$RUN_ID" harvest_state=harvested-unmerged`.
     issue_tracker `harvest --result unmerged --conflicts "<files>"` (§6). Exit 1 (a conflict is
     a named abort — and it makes teardown stop before destroy, which is the safe behavior: the
     VM stays alive, the branch stays fetched).
7. POST-MERGE VERIFICATION (best-effort): run
   `uv run sandbox_mount/host/run_manifest_checks.py "$LOCAL" --manifest "$APP_MANIFEST"`
   (`$APP_MANIFEST` awk-parsed like teardown does, default `sssf.app.yaml`).
   - Runtime missing → the runner prints its named SKIP and exits 0; harvest also prints
     `post-merge checks skipped: runtime not available host-side` when the runner reports all-skip.
   - PASS → `"$RR" set "$RUN_ID" harvest_state=merged merge_sha="$MERGE_SHA"`;
     issue_tracker `harvest --result merged --merge-sha ... --base-ref ...`; report the merge sha.
   - FAIL → revert locally: `git -C "$LOCAL" reset --hard "$PRE"` (covers ff and true merge;
     tree was clean and we checked out base_ref, so this is safe). The run branch stays fetched at
     `refs/harvest/$RUN_ID`. `"$RR" set "$RUN_ID" harvest_state=merge-broke-build`.
     issue_tracker `harvest --result broke-build --merge-sha ...` (§6 reopens the issue). Print
     the failing check names + log paths + how to re-apply (`git merge refs/harvest/$RUN_ID`).
     Exit 1.
8. **NEVER PUSH.** No `git push` anywhere in the recipe; state it in a comment and in the output
   (`merge is local only — push it yourself when ready`).

Idempotency: re-running after a successful merge → `git merge` prints "Already up to date", exits
0; treat as success and re-report the recorded `merge_sha`.

Keep the header's WHY comments; add one explaining the two modes and why merge is the default
(orthogonal parallel features are the common case; competition is the special case) and why push
stays human.

### 5. `just/sandbox/manage/compare.just` + `sandbox_mount/host/compare_runs.py` — NEW

`compare.just` (imported into `manage/mod.just`):

```
compare *RUN_IDS:
    #!/usr/bin/env bash
    ... require at least 2 ids (exit 2 otherwise) ...
    sandbox_mount/host/compare_runs.py {{ RUN_IDS }}
```

`compare_runs.py` — stdlib + the same `sys.path.insert` import of `run_record`. Read-only. Per
run id, print a block:

- run id, `issue_state` (outcome), `issue_url`, `harvest_state`/`merge_sha` when set.
- Commits BASE..HEAD with messages: base = `commit_sha`; ref = `refs/sandbox/<id>` in the app
  cache `.sandbox/repos/<basename(app.repo)>.git` (roster parsed via the same yaml read as
  issue_tracker's `_app_config` — it's fine to import nothing from issue_tracker; duplicate the
  10 lines). If the cache/ref is missing (not harvested), fall back to `refs/harvest/<id>` /
  `sbx/<id>` in `local_path`, else print "not harvested — run `just sbx manage harvest <id>`".
- Diffstat: `git -C <cache> diff --stat <base>..<ref>` (last summary line is enough, but full
  --stat is nicer and cheap).
- Tokens + cost: read the trace db at `.sandbox/runs/<id>-artifacts/<observability.db>` (roster's
  `observability.db`, default `adws/adw_data/sssf.db`) with stdlib sqlite3 —
  `select total_tokens, total_cost, status from sessions order by started_at desc limit 1`.
  Missing db → `tokens/cost: n/a (no artifact db)`. Do NOT ssh to VMs — compare is host-side only.

### 6. `sandbox_mount/host/issue_tracker.py` — close-comment extensions

- Add label: `"sssf:merged-broken": ("d93f0b", "SSSF merge passed textually but broke the checks")`.
- New verb `harvest`:

  ```
  issue_tracker.py harvest RUN_ID --result merged|unmerged|broke-build|bundle-only
                   [--merge-sha SHA] [--base-ref REF] [--conflicts "f1 f2 ..."]
  ```

  Best-effort like everything else (warn, exit 0). All four results post a comment on the run's
  recorded issue (it is normally already CLOSED by the watcher — comments on closed issues are
  fine):
  - `merged` → `merged into <base_ref> as <merge_sha>` (+ note that push stays human).
  - `unmerged` → conflict report: conflicting files, the manual-resolution commands, run marked
    `harvested-unmerged`.
  - `bundle-only` → `bundle-only — awaiting integration decision`.
  - `broke-build` → comment naming the failing checks, then REOPEN:
    `gh issue reopen <n> --repo <repo>`, `gh issue edit --add-label sssf:merged-broken`. The label
    stays until a human resolves and removes it — the tracker never removes it.
- `_harvest_status()` in `_final_comment`: when the run record has `harvest_state`/`merge_sha`
  set, render that line (`merged into <base_ref> as <sha>` etc.) in preference to the bundle
  line. Backwards compatible when the fields are null.

### 7. `just/sandbox/manage/mod.just` — header + import

Add `import 'compare.just'`. Fix the header comment: harvest now writes `harvest_state`/
`merge_sha` to the run record and talks to the issue tracker.

### 8. `.claude/skills/sssf-sandbox-orchestrator/cookbooks/fan_out_n.md` — the two modes

Update "Ranking the arms" and the harvest mentions:

- **Competing arms (best-of-N)**: `just sbx manage harvest <id> --no-merge` per arm (bundle-only;
  there is nothing to merge — the arms are alternatives), then `just sbx manage compare <id1>
  <id2> ...` for the side-by-side table (outcome, commits, diffstat, tokens+cost, issue link).
  Plain-git diff of the refs remains the honest deeper comparison.
- **Parallel-orthogonal arms**: plain `just sbx manage harvest <id>` per arm — each merges into
  `base_ref` in the roster's `app.local_path` clone; conflicts and merge-broke-build surface with
  named states (`harvested-unmerged`, `merge-broke-build`) and manual-resolution commands.

### 9. `.claude/skills/sssf-sandbox-orchestrator/SKILL.md` — mention the modes

Line ~126 and the recipe-table row (~157): harvest is now "merge the run's commits into the app's
local clone (`base_ref`), or `--no-merge` for bundle-only (competing runs)"; add
`just sbx manage compare` to the table. One sentence on the mode split (orthogonal → merge,
competing → bundle-only + compare). Keywords line may gain "merge".

## Verification — for real, on the hello roster (app.repo yhuangsh/hello-server, PUBLIC)

Setup:

```bash
WORK=/tmp/harvest-modes-verify
mkdir -p "$WORK"
git clone -q https://github.com/yhuangsh/hello-server.git "$WORK/hello-server"   # the local clone
# scratch roster = copy of adws/adw_sssf_config/sssf.hello.config.yaml with:
#   app.local_path: /tmp/harvest-modes-verify/hello-server
#   data_dir / observability.db pointed under $WORK (NOT adws/adw_data/local/hello)
# then: export SSSF_CONFIG=$WORK/sssf.hello-merge.config.yaml
bun --version   # must exist host-side, else (d) cannot demonstrate merge-broke-build
```

Every sandbox below: `just sbx mount`-style phases with run ids minted via
`sandbox_mount/host/run_record.py new-id` (fan_out_n.md's concurrency rule), fill pinned to the
SAME hello-server sha (`git ls-remote` HEAD at verification time), setup, execute. Confirm
`.env` has the roster provider keys (`just sbx manage doctor`).

(a) **ORTHOGONAL PAIR** — two concurrent sandboxes on the same repo:
- run 1 executes "add a copyright comment line to server.ts";
- run 2 executes "add a /greet/<name> endpoint with its own test file".
- Both accepted. `just sbx manage harvest <id1>` → merges (expect fast-forward into main);
  `harvest <id2>` → merges, no conflict. Post-merge checks green both times
  (`bun test server.test.ts` host-side). Both issues carry "merged into main as <sha>" comments
  with the actual merge shas — capture the shas + `gh issue view` evidence for the envelope.

(b) **OVERLAPPING PAIR** — two fresh sandboxes, both edit the SAME function in server.ts with
different wording. First harvest merges; second harvest → conflict: `git merge --abort` ran, tree
clean again, conflicting files named, both sides + exact manual-resolution commands printed, run
record `harvest_state=harvested-unmerged`, issue comment added. Capture the full transcript.

(c) **BUNDLE-ONLY** — fresh run; `harvest <id> --no-merge` → bundle verified into the cache at
`refs/sandbox/<id>`, NO merge attempted (local clone untouched — prove with
`git -C $WORK/hello-server status` + `git log` before/after).

(d) **MERGE-BROKE-BUILD** — sandbox A: "change the home page response text to X"; sandbox B:
"update server.test.ts to assert response text Y" (Y ≠ X). Harvest A merges green; harvest B
merges textually clean but post-merge `bun test` FAILS → `git reset --hard` revert (prove main is
back at A's merge sha), `refs/harvest/<idB>` still present, run record
`harvest_state=merge-broke-build`, issue REOPENED with label `sssf:merged-broken`. Capture the
`gh issue view --json state,labels` evidence.

(e) **REGRESSION** —
- Kernel tree: `git status --porcelain` before the whole verification and after — byte-identical
  except the landed feature files (the ones in "Files to change" + this spec).
- `just sbx mount` default hello sandbox: gates A–E green at least once during the session.
- Prove push never happened: `git -C $WORK/hello-server log origin/main..main` empty at the end
  (and `git ls-remote https://github.com/yhuangsh/hello-server.git main` unchanged from the fill
  pin unless a merge was pushed BY HAND — the builder never pushes).
- Cleanup: teardown every sandbox created above (harvest already done; use `--no-harvest` where
  the bundle is already home), verify `ssh exe.dev ls` shows none left. The /tmp workdir and the
  reopened test issue may stay; note the issue number in the envelope.

## Notes / constraints

- Teardown calls plain `just sbx manage harvest "$RUN_ID"` → it now merges by default. That is
  the intended new behavior; a conflict exits 1 and teardown's existing guard stops before
  destroy (VM alive, branch fetched) — safe, and (b) relies on it.
- `just` recipe files imported into the root justfile share ONE scope: no file-level variables in
  harvest.just/compare.just, everything is a bash local (existing header comments explain).
- Never write scratch output into the repo; the scratch roster, local clone, and check logs all
  live under /tmp.
- The chain's commit phase owns all commits; leave the tree dirty.
- Out of scope: the factory repo, parked items, changing `quality.py` (the host-side runner is a
  separate small script that mirrors its check-shape parsing).
