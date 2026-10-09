# Harvest grows two integration modes — MERGE is the new default

`just sbx manage harvest` used to be bundle-only: bring the run's commits home, put them at
`refs/sandbox/<run-id>`, stop. That served the rare "best-of-N, then pick one" case, but the
common multi-sandbox use is **parallel orthogonal features on one repo, all merging into the
trunk** — and that path required the engineer to do the merge by hand every time.

This change turns `harvest` into the default endpoint for that common path:

- **`harvest RUN_ID`** (new default, target mode) — fetch the run branch into the app's **local
  clone** (roster `app.local_path`), merge it into `base_ref`, re-run the manifest's checks
  against the merged tree, report the merge sha. **Never pushes** — a human reviews and pushes.
- **`harvest RUN_ID --no-merge`** — today's bundle-only behavior, for competing runs (fan-out
  / best-of-N where the arms are alternatives, not complements).
- **`just sbx manage compare <id1> <id2> ...`** — read-only side-by-side report: outcome,
  commits BASE..HEAD, diffstat, tokens + cost, issue link. This is the ranking view for the
  bundle-only arms.

The merge step is **non-destructive by construction**: it requires a clean working tree, aborts
on conflict with the exact manual-resolution commands (the run branch stays fetched), and reverts
locally if the post-merge checks fail. Every outcome (`merged` / `harvested-unmerged` /
`merge-broke-build` / `bundle-only`) is recorded on the run record AND mirrored as a comment on
the run's GitHub issue (the issue is **reopened** with `sssf:merged-broken` when a textual merge
broke the build, until a human resolves it).

## Why it matters

The harvest recipe used to stop at the bundle boundary: the work was **at home** but not **on the
trunk**. The engineer's merge was post-harvest, manual, and unobserved by the system — so there
was no audit record of "this run shipped to main as `<sha>`", nothing on the issue tracker
reflected the integration outcome, and a fan-out cook book had to teach the merge by hand for every
arm. Now the common path is one command and the rare path is one flag — and the run record /
issue tracker capture the outcome either way, so a best-of-N decision reads off one screen instead
of a scavenger hunt.

## Where the change lives

### Run record — schema extension (sanctioned field path)

- **`sandbox_mount/host/run_record.py`** — adds five fields to the closed `FIELDS` tuple,
  extending the same pattern as the issue-tracking block and `ports`:
  - `base_ref` — the branch the run started from (roster `app.ref`, default `main`).
  - `base_sha` — the sha `base_ref` pointed at when the run filled (duplicates `commit_sha`
    today; both are kept because `commit_sha` stays harvest's bundle baseline and `base_sha` is
    the merge anchor).
  - `merge_mode` — `merge` (default, seeded in `create()`) | `bundle-only`.
  - `harvest_state` — null | `bundle-only` | `merged` | `harvested-unmerged` | `merge-broke-build`.
  - `merge_sha` — the merge commit (or fast-forward tip) sha in the local clone.

### FILL — record the merge anchor

- **`just/sandbox/lifecycle/fill.just`** — in TARGET mode (the `commit_sha="$TARGET_SHA"` line at
  the end of the target branch), parses `app.ref` from the roster with the existing awk idiom
  (default `main` when empty) and writes `base_ref="$APP_REF" base_sha="$TARGET_SHA"`. In vendored
  mode, writes `merge_mode=bundle-only` explicitly — vendored runs have no separate app clone
  to merge into.

### Host-side check runner — new script

- **`sandbox_mount/host/run_manifest_checks.py`** — *new*, 146 lines. A PEP-723 uv script
  (pyyaml only) that runs an app manifest's `checks:` against a host-side tree. Mirrors
  `adws/adw_modules/quality.py`'s check-shape parsing — accepts BOTH the MAP shape
  (`{test: [bun, test, server.test.ts]}` — hello-server's shape) and the LIST shape (with
  `name/area/operation/argv/timeout_seconds`), defaulting timeout to 120s. A check whose `argv[0]`
  is not on PATH is **SKIP**ped with a named line (`SKIP <name>: runtime '<argv0>' not available
  host-side`) and is not a failure. Skips are recoverable from the host; only a real check
  failure exits 1 and is reported by name. Logs live under a tempdir — never into the app tree
  (which has to stay clean) or the kernel repo.

### HARVEST — the two modes

- **`just/sandbox/manage/harvest.just`** — signature becomes `harvest RUN_ID *FLAGS` (parsed the
  same way teardown parses `--no-harvest`). The entire bundle/verify/fetch half is unchanged and
  runs first in BOTH modes (the bundle is the durable return-trip record of the work). What
  changes:
  - **`--no-merge`** → stop after the bundle fetch, write `harvest_state=bundle-only`, post a
    `bundle-only — awaiting integration decision` comment on the issue. Exit 0. Vendored mode
    also writes `bundle-only` (no separate app clone) and stops.
  - **Default** (target mode) continues into the local clone, in order:
    1. Resolve `app.local_path` from the roster (expand `~`). Empty/missing → **named fallback**
       (not an error): print `harvest: no app.local_path in roster — bundle-only` plus the exact
       three manual `git fetch/merge/checkout` commands, write `harvest_state=bundle-only`, exit 0.
    2. `local_path` must exist and be a git repo → else named abort (exit 1) with the manual
       commands; bundle stays, VM stays.
    3. **Require a clean working tree** → else named abort
       (`harvest: local clone at $LOCAL has uncommitted changes — clean it or use --no-merge`,
       exit 1). Nothing has been touched in the clone yet.
    4. Fetch the run branch into the clone at `refs/harvest/$RUN_ID` from the bare cache
       `.sandbox/repos/<app>.git`.
    5. Checkout `base_ref` (from the run record; default `main` if empty). If `base_ref` does
       not exist in the clone → named abort with manual instructions.
    6. `git -C "$LOCAL" merge --no-edit "refs/harvest/$RUN_ID"` (fast-forward or true merge).
       - **Conflict** → capture the conflicting files via `git diff --name-only --diff-filter=U`;
         `git merge --abort` (fallback to `git reset --hard $PRE`); print the file list + the
         run-branch side (`git log --oneline $base_ref..$HARVEST_REF`) + the current `base_ref`
         tip + the manual-resolution commands (the fetch already happened, so the engineer just
         checks out `base_ref`, runs `git merge refs/harvest/$RUN_ID`, resolves, adds, commits).
         Write `harvest_state=harvested-unmerged`; post the issue comment (conflict report, both
         sides, manual commands). Exit 1 — and teardown's existing harvest-failure guard stops
         before destroy, so the VM stays alive and the branch stays fetched (this is the safe
         behavior, and the spec's (b) OVERLAPPING PAIR scenario relies on it).
       - **Success** → capture `MERGE_SHA` and proceed to verification. A re-harvest after a
         successful merge sees "Already up to date" from git and re-reports the recorded
         `merge_sha` without rewriting it (which would drift to the moved clone tip after sibling
         merges move HEAD).
    7. **Post-merge verification (best-effort)**: run `run_manifest_checks.py` against the merged
       tree. All runtime missing → a named skip line, exit 0. PASS → write
       `harvest_state=merged merge_sha="$MERGE_SHA"`, post the merged comment, report the sha.
       FAIL → `git reset --hard $PRE` (covers both ff and true merge, tree was clean so this is
       lossless), write `harvest_state=merge-broke-build`, post the broke-build comment (the
       issue-tracker verb reopens the issue with `sssf:merged-broken`), exit 1. Print the failing
       check names and `git merge refs/harvest/$RUN_ID` to re-apply later.
  - Header comments spell out why MERGE is the default (orthogonal parallel features are the
    common case; competition is the special case) and why push stays human.
- **`just/sandbox/manage/mod.just`** — imports `compare.just`; header comment updated: harvest now
  writes `harvest_state`/`merge_sha` to the run record and talks to the issue tracker.

### COMPARE — new read-only recipe

- **`just/sandbox/manage/compare.just`** — *new*. `compare <id1> <id2> ...` recipe; requires at
  least two run ids (exit 2 otherwise); delegates to `compare_runs.py`.
- **`sandbox_mount/host/compare_runs.py`** — *new*, 167 lines. Stdlib + `run_record.py` via the
  same `sys.path.insert` idiom; pyyaml for the roster read. Per run id prints a block:
  - `outcome: <issue_state>` (the tracker's verdict) and `issue: <url>` (when recorded).
  - `harvest: <state-derived line>` — uses the record's `harvest_state` + `merge_sha` /
    `base_ref`: `merged into <base> as <sha>`, `harvested-unmerged (conflict merging into
    <base>)`, `merge-broke-build (reverted; merge sha <sha>)`, or
    `bundle-only (awaiting integration decision)`. An unharvested run prints `not harvested`.
  - `commits (<base>..<ref>):` — `git log --format=%h %s <base>..<ref>` from the harvested app
    cache (`.sandbox/repos/<basename(app.repo)>.git`, ref `refs/sandbox/<id>`); falls back to
    `refs/harvest/<id>` or `sbx/<id>` in the local clone when the cache is missing.
  - `diffstat:` — `git diff --stat <base>..<ref>` from the same source.
  - `tokens/cost:` — reads the pulled artifact db at
    `.sandbox/runs/<id>-artifacts/<roster observability.db>` (default
    `adws/adw_data/sssf.db`) via stdlib `sqlite3`:
    `select total_tokens, total_cost, status from sessions order by started_at desc limit 1`.
    Missing db → `n/a (no artifact db)`. **Never ssh** to VMs — compare is host-side only.

### Issue tracker — close-comment extensions

- **`sandbox_mount/host/issue_tracker.py`** —
  - Adds label `"sssf:merged-broken": ("d93f0b", "SSSF merge passed textually but broke the
    checks")`.
  - New subcommand `harvest RUN_ID --result merged|unmerged|broke-build|bundle-only
    [--merge-sha SHA] [--base-ref REF] [--conflicts "f1 f2 ..."] [--failing-checks "..."]`.
    Best-effort (warn, exit 0 on failure). All four results post a comment on the run's recorded
    issue. `broke-build` additionally reopens the issue and applies `sssf:merged-broken`; the
    label stays until a human removes it (the tracker never removes it).
  - `_harvest_status()` (in the final close comment) renders the record's
    `harvest_state`/`merge_sha`/`base_ref` when set, in preference to the bundle line. Backwards
    compatible: when the new fields are null, the bundle line still wins.

### Cookbooks and skill

- **`.claude/skills/sssf-sandbox-orchestrator/cookbooks/fan_out_n.md`** — "Ranking the arms"
  splits into **Competing arms** (best-of-N) — `harvest --no-merge` per arm, then
  `compare <id1> <id2> ...` for the side-by-side table — and **Parallel-orthogonal arms** —
  plain `harvest <id>` per arm; conflicts and merge-broke-build surface with named states
  (`harvested-unmerged`, `merge-broke-build`) and manual-resolution commands. The teardown
  section calls out that teardown's plain `harvest` now merges by default — competing arms should
  be `harvest --no-merge` first, or teardown with `--no-harvest`.
- **`.claude/skills/sssf-sandbox-orchestrator/SKILL.md`** — keywords line gains `merge`,
  `bundle`, `compare`; harvest is now described as merging into `base_ref` (default) or
  `--no-merge` for bundle-only; recipe table gains the `harvest --no-merge` and `compare` rows
  and a one-sentence mode split (orthogonal → merge, competing → bundle-only + compare).

### Spec

- **`specs/fd43ce2c_harvest-merge-modes.md`** — *new*, 292 lines. The design doc this write-up
  summarizes, with the (a)-(e) verification plan and the design decisions named at each step.

## How to use it

**Default merge** (the new common path) — once a sandbox's `execute` finishes:

```bash
just sbx manage harvest <run-id>           # bundle + fetch + merge + verify + comment
just sbx manage compare <id1> <id2> ...    # side-by-side for any set of harvested runs
```

For the merge to land, the roster must name `app.local_path` and the directory must be a git
repo on a clean tree; otherwise harvest reports the named state and prints the exact manual
commands. Push remains a human step.

**Competing arms** (best-of-N where the arms are alternatives):

```bash
just sbx manage harvest <id1> --no-merge   # bundle only — there is nothing to merge
just sbx manage harvest <id2> --no-merge
just sbx manage compare <id1> <id2>
```

## How to verify it

The full live-verification plan is in `specs/fd43ce2c_harvest-merge-modes.md → Verification`:

- **(a) ORTHOGONAL PAIR** — two concurrent sandboxes on the same `yhuangsh/hello-server` clone;
  one adds a comment, one adds a `/greet/<name>` endpoint + test. Both harvest → merge → checks
  green → issue comments carry the merge shas.
- **(b) OVERLAPPING PAIR** — two fresh sandboxes both edit the same function with different
  wording. First harvest merges; second harvest hits a conflict, `git merge --abort` runs, the
  conflicting files + both sides + manual commands are printed, `harvest_state=harvested-unmerged`,
  issue comment added. (Teardown's pre-existing harvest-failure guard prevents the VM from being
  destroyed.)
- **(c) BUNDLE-ONLY** — `harvest <id> --no-merge` on a fresh run: bundle at `.sandbox/runs/`,
  ref `refs/sandbox/<id>` in `.sandbox/repos/<app>.git`; local clone untouched
  (`git -C <local> status` and `git log` prove it).
- **(d) MERGE-BROKE-BUILD** — sandbox A changes the home page text to X, sandbox B updates the
  test to assert text Y (≠ X). A merges green; B merges textually clean but post-merge `bun
  test` fails → `git reset --hard $PRE` reverts, `refs/harvest/<idB>` still present,
  `harvest_state=merge-broke-build`, issue REOPENED with label `sssf:merged-broken`.
- **(e) REGRESSION** — kernel tree byte-identical before/after except the landed files;
  default-sandbox mount gates A-E green at least once; `git -C <local> log origin/main..main`
  empty at end (push never performed by the builder).

Quick sanity (no sandbox needed) — after the code lands, the new menu entries exist as named
states, and the new subcommand parses:

```bash
just sbx manage                              # namespace lists 'compare' alongside harvest
just sbx manage harvest --help              # unknown flag check (parses *FLAGS)
uv run sandbox_mount/host/run_manifest_checks.py /nonexistent --manifest sssf.app.yaml
                                              # named SKIP, exit 0
uv run sandbox_mount/host/issue_tracker.py harvest --help
                                              # shows merged|unmerged|broke-build|bundle-only
```

The spec's `(c) BUNDLE-ONLY` is the cheapest end-to-end check that exercises the new code path
on a real VM: a `harvest --no-merge` of any recorded run produces a bundle, writes
`harvest_state=bundle-only`, and posts the issue comment.
