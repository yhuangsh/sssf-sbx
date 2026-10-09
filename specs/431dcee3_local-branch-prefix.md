# Rename the LOCAL lane's run-branch prefix `sbx/` -> `local/`

## Goal

The LOCAL lane (`just local …`) creates its run branch as `sbx/<run-id>` —
inconsistent with the `local` namespace. Rename it to `local/<run-id>` **in the
LOCAL lane only**. The sandbox lane (`just sbx …`) keeps `sbx/` everywhere.

## Current state (verified by recon)

- `just/local.just` holds the only branch-name computation in the LOCAL lane:
  - line 140: `BRANCH="sbx/{{RUN_ID}}"` (mount recipe)
  - line 188: `BRANCH="sbx/{{RUN_ID}}"` (execute recipe, used for the
    "payload is on the right branch" guard)
  - plus three comments mentioning `sbx/<run-id>`: lines 19, 45, 139.
- `README.md` LOCAL-section mentions: lines 417, 420, 503, 512 (all
  `sbx/<run-id>`). Line 47 (sandbox Integration section) is correct and stays.
- The issue tracker's commits section is **branch-agnostic** (confirms verify
  (d) by inspection): `sandbox_mount/host/issue_tracker.py:414-428`,
  `_commits()` runs `git -C <local_path> log <base>..HEAD` for local runs — no
  branch name anywhere. It resolves BASE..HEAD whatever the prefix is.
- The hello roster `adws/adw_sssf_config/sssf.hello.config.yaml` is
  **git-tracked** and has `local_path:` commented out — do NOT edit it for the
  behavioral verify; use a /tmp copy (see below).

## Changes

### 1. `just/local.just` — 5 spots

| line | from | to |
|------|------|----|
| 19 (comment) | ``run branch `sbx/<run-id>` `` | ``run branch `local/<run-id>` `` |
| 45 (comment) | `create the run branch sbx/<run-id>` | `create the run branch local/<run-id>` |
| 139 (comment) | `run branch sbx/<run-id> (create or switch)` | `run branch local/<run-id> (create or switch)` |
| 140 | `BRANCH="sbx/{{RUN_ID}}"` | `BRANCH="local/{{RUN_ID}}"` |
| 188 | `BRANCH="sbx/{{RUN_ID}}"` | `BRANCH="local/{{RUN_ID}}"` |

Nothing else in the recipe bodies references the prefix — mount's
create-or-switch logic and execute's branch guard are prefix-agnostic once
`BRANCH` changes.

### 2. `README.md` — 4 spots, LOCAL workflow sections only

| line | change |
|------|--------|
| 417 | `run branch sbx/<run-id>` -> `run branch local/<run-id>` |
| 420 | `commits land on sbx/<run-id>` -> `commits land on local/<run-id>` |
| 503 | ``branch `sbx/<run-id>` is the boundary`` -> ``branch `local/<run-id>` is the boundary`` |
| 512 | `` `sbx/<run-id>` in the clone`` -> `` `local/<run-id>` in the clone`` |

**Do not touch** line 47 (sandbox Integration section `sbx/<run-id>`) or any
other sandbox-lane mention.

## Out of scope — known-stale after the rename, deliberately NOT changed

Flag these in the final report so the operator sees them consciously; the
prompt restricts scope to (1) and (2):

- `sandbox_mount/host/issue_tracker.py:464` and `:630` — LOCAL-mode **message
  strings** that print `sbx/{run_id}` ("commits are on branch `sbx/<id>`…",
  "surviving state … on branch `sbx/<id>`"). Cosmetic-only staleness; the
  commits section itself is branch-agnostic (see (d)).
- `sandbox_mount/host/scaffold.py:884` — local preset's next-steps print
  mentions `branch sbx/<run-id>`.
- `.claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md` lines
  ~72, 82, 87, 105 — LOCAL-lane cookbook mentions `sbx/<run-id>`.
- `specs/*`, `app_docs/*` — historical records; never edit.
- `just/sandbox/**`, `adws/adw_sssf_config/sssf.*.config.yaml` comments —
  describe the sandbox lane; `sbx/` is correct there.

Also note: after the rename, a run mounted **before** this change (branch
`sbx/<id>`) will fail `just local execute`'s branch guard — expected; re-mount.

## Verify

### (a) grep

- `grep -n 'sbx/' just/local.just` -> **no output** (exit 1).
- `grep -cn 'local/{{RUN_ID}}' just/local.just` -> 2.
- `sed -n '400,520p' README.md | grep 'sbx/'` -> no output; the LOCAL sections
  now say `local/<run-id>` (`grep -c 'local/<run-id>' README.md` >= 4).
- `sed -n '47p' README.md` still contains `sbx/<run-id>`.

### (b) behavioral — local lane on the hello roster

Do **not** edit the tracked hello roster. Copy it and set `local_path`:

1. `cp adws/adw_sssf_config/sssf.hello.config.yaml /tmp/sssf.hello-local.config.yaml`
   and under its `app:` block set `local_path: /tmp/hello-payload` (two-space
   indent, sibling of `repo:`). Fresh dir or absent — mount clones.
2. `export SSSF_CONFIG=/tmp/sssf.hello-local.config.yaml`
3. `just local mount rename-check` — clones hello-server if missing, creates
   the run branch.
4. `git -C /tmp/hello-payload branch --show-current` -> `local/rename-check`.
5. Small execute: `just local execute rename-check simple-sdlc "add a one-line
   comment to the README"` (real chain, real LLM calls — keep the prompt
   tiny). Afterwards `git -C /tmp/hello-payload log --oneline -3` shows the
   chain's commit on `local/rename-check`, and
   `git -C /tmp/hello-payload branch --show-current` is still
   `local/rename-check`.
6. Cleanup is manual (local mode has no teardown): the clone and the
   `local/rename-check` branch persist in /tmp; leave or `rm -rf
   /tmp/hello-payload` — your call, but say which in the report.

### (c) sandbox regression

1. `export SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`
2. `just sbx mount sbxreg-check` — real exe.dev VM, real cost, a few minutes.
   If exe.dev credentials are unavailable, report this step **blocked**, do
   not silently skip.
3. `just sbx run cmd sbxreg-check 'git -C app/target branch --show-current'`
   -> `sbx/sbxreg-check`. Gate A reporting in the mount output unchanged.
4. `just sbx lifecycle teardown sbxreg-check` — always tear down.

### (d) issue tracker commits section

Already confirmed by inspection (`_commits()`, issue_tracker.py:414-428:
`git log <base>..HEAD`, no branch name). Behaviorally: if `gh` auth against
the app repo works, the issue opened/closed by step (b)5 has a "Commits
(BASE..HEAD)" section listing the execute's commit. If issue open failed
best-effort (no gh auth), the code inspection stands — say so in the report.

## Done means

(a)-(d) demonstrated, the rename landed **by this chain** (the commit phase
owns the commit), and the kernel tree is clean afterwards (`git status`
porcelain empty apart from anything the chain itself committed).
`changed_files` lists only files that exist afterwards: `just/local.just`,
`README.md`.
