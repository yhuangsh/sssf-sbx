# GitHub-issue tracking for every ADW session

One GitHub issue per ADW session, **in the app's own repo** (the roster's `app.repo`;
target mode only). The issue is the durable audit record of instruction → outcome:
opened before the SDLC starts, commented at milestones, closed with the final verdict.

Target roster for verification: `adws/adw_sssf_config/sssf.hello.config.yaml`
(`app.repo: https://github.com/yhuangsh/hello-server.git`). `gh` 2.46 is installed on
the host and authenticated (account `yhuangsh`, `repo` scope). `uv` 0.11.14 on the host.

## Hard rules (from the proposal — implement exactly)

- **Host-side only.** `gh` credentials NEVER enter the VM. The tracker runs on the
  host; its only VM contact is read-only `ssh … python3/sqlite3` trace queries. Assert
  this in verification (h).
- **Best-effort everywhere.** Every tracker invocation is wrapped so a failure warns
  and never fails mount/execute/teardown.
- `SSSF_ISSUES=0` disables entirely, with a named skip message.
- Vendored mode (roster has no `app.repo`) skips with a named skip message.
- Issue bodies must never contain secret VALUES (redaction pass, below).
- The chain's commit phase owns all commits. Leave the tree dirty; `changed_files`
  lists only files that exist afterwards.

## Files to touch

| File | Change |
|---|---|
| `sandbox_mount/host/issue_tracker.py` | **NEW** — uv PEP-723 script, the whole feature core |
| `sandbox_mount/host/run_record.py` | Extend `FIELDS` + `_COERCE` (the sanctioned field-extension pattern; precedent: `ports`) |
| `just/sandbox/lifecycle/execute.just` | Hooks: tracker `open` before launch, detached watcher after |
| `just/sandbox/lifecycle/teardown.just` | Hook: cancel an issue still open at teardown |
| `just/sandbox/manage/sync_issues.just` | **NEW** — `sync-issues` recipe |
| `just/sandbox/manage/mod.just` | `import 'sync_issues.just'` |
| `README.md` | New "Session tracking (GitHub issues)" section right after the `## Use` loop |

No changes to `adws/` (the trace db schema already carries everything needed).

## 1. `sandbox_mount/host/run_record.py` — extend the closed schema

Add to `FIELDS` (this is the sanctioned extension path; unknown keys are rejected, so
the tracker cannot work without this):

```
"issue_url",          # str, https://github.com/<owner>/<repo>/issues/<n>
"issue_number",       # int
"issue_state",        # str: open | accepted | failed | cancelled  (tracker's view)
"prev_issue_number",  # int — the issue this run record's previous execute opened
```

Add to `_COERCE`: `"issue_number": "int"`, `"prev_issue_number": "int"`.
Nothing else changes — `set`/`get`/`close`/`list` work unchanged.

## 2. `sandbox_mount/host/issue_tracker.py` — NEW

uv PEP-723 script, matching the established pattern (observe.just already runs
`uv run -` with a `# /// script / dependencies = ["pyyaml"]` header):

```python
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
```

CLI (argparse subcommands, mirroring run_record.py's shape):

```
issue_tracker.py open   RUN_ID --instruction TEXT      # create issue, record fields
issue_tracker.py update RUN_ID --milestone NAME [--db PATH]  # append milestone comment
issue_tracker.py close  RUN_ID --outcome accepted|failed|cancelled [--db PATH] [--note TEXT]
issue_tracker.py watch  RUN_ID --since ISO_TS          # the watcher loop (see §3)
issue_tracker.py sync                                  # reconciliation sweep (see §5)
```

Shared internals:

- **Record + roster resolution.** Read the run record by importing nothing —
  shell out to `run_record.py get RUN_ID` (JSON) exactly like the just recipes do, or
  `sys.path.insert` the host dir and import `run_record` (either is fine; importing is
  cleaner, both run on the host). Resolve the roster via `SSSF_CONFIG`
  (`require_sssf_config.sh` semantics: unset → named error) and parse `app.repo` /
  `app.path` with pyyaml. If `app.repo` is empty → print the vendored skip message and
  exit 0 (skip is not an error).
- **gh wrapper.** `subprocess.run(["gh", ...], capture_output=True, text=True)`.
  Never log the token; never pass `GH_TOKEN` anywhere (gh reads its own host config).
- **Labels.** `ensure_labels(repo)`: `gh label create sssf:running … --force` (and
  `sssf:accepted`, `sssf:failed`, `sssf:cancelled`, `sssf:follow-up`) — `--force` makes
  create idempotent.
- **Trace access.** `_trace(RUN_ID)` → dict with `session`, `phases`, `gates`,
  `envelopes`, `commits`. Reads from, in order: (1) `--db PATH` if given (sync path,
  pointing at the teardown artifact copy); (2) the live VM via
  `ssh <vm>.exe.xyz python3 - <<…` running a stdlib sqlite3 query script against
  `/home/exedev/app/adws/adw_data/sssf.db` that emits JSON on stdout (python3 is
  guaranteed on exeuntu — observe.just and teardown already rely on it; do NOT depend
  on a `sqlite3` CLI on the VM); (3) `.sandbox/runs/<RUN_ID>-artifacts/adws/adw_data/sssf.db`
  if it exists (teardown pulls exactly this file). Queries:
  - session: `SELECT adw_id, adw_name, request, status, started_at, ended_at, total_tokens, total_cost FROM sessions ORDER BY started_at DESC LIMIT 1` (or by adw_id when known)
  - phases: `SELECT seq, name, kind, owner, status, error, started_at, ended_at FROM phases WHERE adw_id=? ORDER BY seq`
  - gates: `SELECT gate, passed, violations_json, checks_json FROM gate_results WHERE adw_id=?`
  - review verdicts: `SELECT agent, output_type, payload_json FROM envelopes WHERE adw_id=? AND output_type LIKE '%eview%'` (ReviewReport etc.; pull verdict/summary fields out of payload_json defensively)
  - commits BASE..HEAD: on a live VM, `ssh … git -C app/<app.path> log --format='%h %s' <commit_sha>..HEAD` (target mode repo dir = `app/<app.path>`, same rule as harvest.just); with no VM, `git -C .sandbox/repos/<basename(app.repo)>.git log --format='%h %s' <commit_sha>..refs/sandbox/<RUN_ID>` when that cache exists (harvest creates it).
- **Redaction.** Before any body/comment leaves the host, replace every value of every
  host env var whose name matches `(KEY|TOKEN|SECRET|PASSWORD)` and whose value is ≥ 8
  chars with `***REDACTED***`. Issue content is assembled from instruction text, run
  metadata, trace rows, commit subjects, and error strings — never from `.env` — but
  the pass is the belt to that suspenders, and verification (h) asserts it.

### `open RUN_ID --instruction TEXT`

1. Guards: `SSSF_ISSUES=0` → named skip, exit 0. No `app.repo` → named skip
   (`issues: vendored mode — roster has no app.repo; skipping issue tracking`), exit 0.
   No `gh auth` → warn, exit 0 (best-effort).
2. Follow-up detection: read the record's current `issue_number`. If set, ask gh for
   that issue (`gh issue view N --repo R --json state,labels,stateReason`); if it was
   closed with the `sssf:failed` label (or `stateReason: NOT_PLANNED` + failed), this
   run is a follow-up: remember `prev=N`.
3. `ensure_labels`.
4. Title: the instruction VERBATIM, truncated to ~200 chars with `…` only if longer
   (gh titles cap at 256). Body (see anatomy below) with `Follow-up to #N` at the top
   when applicable.
5. `gh issue create --repo <app.repo> --title … --body … --label sssf:running
   [--label sssf:follow-up]` → parse the URL, derive the number.
6. `run_record.py set RUN_ID issue_url=… issue_number=N issue_state=open
   [prev_issue_number=N]` (via the CLI so coercion/validation stay centralized).

### Issue anatomy (body template — `open` writes §1–2; `close` writes the rest as the final comment)

1. **Instruction** — the execute prompt VERBATIM, in a fenced block.
2. **Provenance** — run id, roster (basename), factory sha (`factory_sha` field),
   target HEAD (`commit_sha` = the base the run branched from), VM name + tag,
   chain (`adw_name` from the session row, e.g. `adw_plan + adw_build_test`; at open
   time the ADW arg from execute is known — pass it through as `--chain` or fill it at
   first update from the db), `created_at` timestamp.
3. **Phase timeline** — every phase row: seq, name, kind, status, duration
   (ended_at − started_at).
4. **Review verdicts** — from the review envelopes (verdict + summary per attempt).
5. **Commits** — `BASE..HEAD` subjects on the target run branch.
6. **Cost** — `total_tokens` + `total_cost` ($) from the session row.
7. **Outcome** — the final outcome reason VERBATIM (failing phase error text for
   failed; the close note for cancelled; acceptance summary for accepted).
8. **Harvest status** — whether `.sandbox/runs/<RUN_ID>.bundle` exists and how many
   commits it carried (read from the run record / bundle presence; a sentence, not a guess).
9. **Follow-up** — `Follow-up to #N` linkage when applicable.

### `update RUN_ID --milestone NAME`

Read the trace, append ONE comment: milestone name, timestamp, phase timeline so far,
running cost so far. Idempotency guard: `gh issue view --json comments` and skip if a
comment with the same milestone marker (`<!-- sssf:milestone:NAME -->`) already exists.

### `close RUN_ID --outcome …`

Idempotent: if `gh issue view` says the issue is already closed, warn and exit 0.

- **accepted** — final comment (full anatomy §3–8, outcome reason), remove
  `sssf:running`, add `sssf:accepted`, `gh issue close --reason completed`.
- **failed** — final comment with **failure forensics**: failing phase (first phase
  row with `status='fail'`: name, kind, owner, attempt), gate/review detail (failed
  `gate_results` rows: gate name + failing checks + violations), `error` verbatim,
  and a surviving-state note (VM name still alive / record state / where the bundle
  and artifacts live). Remove `sssf:running`, add `sssf:failed`,
  `gh issue close --reason "not planned"`.
- **cancelled** — comment with the state-at-teardown note (`--note`), phase timeline
  as far as it got; add `sssf:cancelled`, close `--reason "not planned"`.

Then `run_record.py set RUN_ID issue_state=<outcome>`.

### `watch RUN_ID --since ISO_TS` — the detached watcher

Runs on the HOST (spawned by execute.just with the same nohup pattern as the SDLC).
Loop every ~30s, hard cap ~6h:

1. Find the session: `SELECT … FROM sessions WHERE started_at >= <since> ORDER BY
   started_at ASC LIMIT 1` (execute captures `since` BEFORE launch; this handles the
   adw_id not being known at launch time).
2. Milestone: once any phase whose name matches `review%` reaches `status='success'`
   (or `ended_at` non-null) and no `<!-- sssf:milestone:review -->` comment exists →
   `update --milestone review`. Coarse, one-shot, exactly as proposed.
3. Completion: session `status` = `success` → `close --outcome accepted`;
   `fail` → `close --outcome failed`. Then exit 0.
4. ssh/VM errors: retry a few times, then warn and exit — teardown and `sync` are the
   backstops. Every watcher failure is a log line, never a non-zero that matters.

Watcher log: `.sandbox/runs/<RUN_ID>.watcher.log` (gitignored, alongside the bundle).

### `sync` — reconciliation sweep

For every run record (`run_record.py list`) with `issue_number` set and
`issue_state=open` (or null):

1. `gh issue view` — if the issue is already closed, just fix the record
   (`issue_state` from labels) and move on.
2. Find the trace: live VM (record has vm_name, VM answers ssh) → live db; else
   `.sandbox/runs/<RUN_ID>-artifacts/adws/adw_data/sssf.db` → `--db`.
3. Session finished (`success`/`fail`) → `close` with that outcome.
   Session absent/still `running` but the record is closed (`closed_at` set) →
   `close --outcome cancelled` with a "reconciled by sync-issues" note.
   Still genuinely running → leave alone, say so.
4. Records with no `issue_number` (disabled/vendored runs) are skipped silently-ish
   (one summary line at the end: N reconciled, M still running, K skipped).

## 3. `just/sandbox/lifecycle/execute.just` — hooks

Insert AFTER the roster-resolution block (`CFG_ARG` is set, roster exists check passed)
and BEFORE the detached SDLC launch:

```bash
# ── issue tracking (best-effort; never fails the execute) ────────────────────
TRACKER="{{justfile_directory()}}/sandbox_mount/host/issue_tracker.py"
ISSUES_ON=1
if [ "${SSSF_ISSUES:-1}" = "0" ]; then
    ISSUES_ON=0
    echo "→ issues: disabled (SSSF_ISSUES=0) — skipping issue tracking"
elif ! grep -qE '^[[:space:]]+repo:[[:space:]]*\S' <<< "$(ssh "$VM".exe.xyz "cat $(printf '%q' "$CONFIG")" 2>/dev/null | awk '/^app:/{a=1;next} /^[^[:space:]]/{a=0} a')" ; then
    ISSUES_ON=0
    echo "→ issues: vendored mode (roster has no app.repo) — skipping issue tracking"
fi
if [ "$ISSUES_ON" = 1 ]; then
    SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    uv run "$TRACKER" open {{RUN_ID}} --instruction "$PROMPT" \
        || echo "!! issue open failed (best-effort) — continuing without it" >&2
fi
```

Notes for the builder:
- The roster is the VM copy at `$CONFIG`; but parsing the HOST's `$SSSF_CONFIG` roster
  with the same awk one-liner used in teardown/harvest is equally correct and avoids a
  round trip — prefer the host roster when `SSSF_CONFIG` is set (execute already
  documents the per-sandbox copy as the default; the simplest correct check is: run
  the awk against `$SSSF_CONFIG` if set, else against the remote copy). Either way the
  skip message must be the vendored one above.
- `open` gets the PROMPT VERBATIM (the already-quoted `$PROMPT` variable).
- A failure of `date`, `uv`, or the tracker must not abort — the `|| echo` covers the
  tracker; the guard block itself must not run under anything that can `exit 1`.

Then AFTER the PID is recorded (`run_record.py set … pid=`), spawn the watcher with the
SAME three detachment pieces the SDLC uses (nohup + redirect + `< /dev/null`), but
LOCALLY (the watcher is a host process; do not ssh):

```bash
if [ "$ISSUES_ON" = 1 ]; then
    ( nohup uv run "$TRACKER" watch {{RUN_ID}} --since "$SINCE" \
        > ".sandbox/runs/{{RUN_ID}}.watcher.log" 2>&1 < /dev/null & echo "→ issue watcher pid $!" )
fi
```

Also update the header comment block of execute.just (the file documents its own
contract; add the issue-tracking behavior, the env var, and the skip messages there).

## 4. `just/sandbox/lifecycle/teardown.just` — cancel-on-teardown

Insert a new step between harvest (step 2) and destroy (step 3) — after harvest so the
commits section of the final comment can read the bundle/cache, before destroy so a
live VM can still answer trace queries:

```bash
# ── 2.5 issue tracking: a still-open issue at teardown means the run was cancelled ──
if [ "${SSSF_ISSUES:-1}" != "0" ]; then
    ISSUE_NUM=$("$RR" get "$RUN_ID" issue_number 2>/dev/null || true)
    if [ -n "$ISSUE_NUM" ]; then
        uv run sandbox_mount/host/issue_tracker.py close "$RUN_ID" --outcome cancelled \
            --note "closed at teardown $(date -u +%Y-%m-%dT%H:%M:%SZ); VM ${VM:-gone}; harvest $([ \"$HARVEST\" = 1 ] && echo ran || echo skipped)" \
            || echo "   issues: close-at-teardown failed (best-effort) — run 'just sbx manage sync-issues'"
    fi
else
    echo "   issues: disabled (SSSF_ISSUES=0)"
fi
```

`close` is idempotent (already-closed → warn, exit 0), so the normal
watcher-beat-teardown case costs one gh call and no churn. Update teardown.just's
header comment (order-of-steps paragraph) to mention step 2.5.

## 5. `just/sandbox/manage/sync_issues.just` + `manage/mod.just`

New file, same header conventions as `list.just` (imported by the root via
manage/mod.just — no `set` lines, no file-level variables):

```just
# reconcile issues for runs whose watcher died (host reboot, killed watcher)
sync-issues:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{ justfile_directory() }}"
    if [ "${SSSF_ISSUES:-1}" = "0" ]; then
        echo "sync-issues: disabled (SSSF_ISSUES=0)"
        exit 0
    fi
    uv run sandbox_mount/host/issue_tracker.py sync
```

Add `import 'sync_issues.just'` to `just/sandbox/manage/mod.just` next to the other
two imports, and one line to its header comment block.

## 6. `README.md` — "Session tracking (GitHub issues)"

New subsection immediately after the `## Use` loop code block (before the lane-mental-model
follow-ons grow stale — put it right after the "The loop" block, as its own `###`).
Contents, concise:

- **What opens when**: `execute` opens one issue per run in the roster's `app.repo`
  before the SDLC starts (title = your instruction verbatim, label `sssf:running`),
  a host-side watcher adds one milestone comment when the review phase completes and
  closes the issue with the full audit record (instruction, provenance, phase
  timeline, review verdicts, commits BASE..HEAD, cost, outcome, harvest status) when
  the session ends.
- **State table**:

  | label | meaning |
  |---|---|
  | `sssf:running` | issue open, session in flight |
  | `sssf:accepted` | session succeeded — closed as completed |
  | `sssf:failed` | session failed — closed as not planned, with failure forensics |
  | `sssf:cancelled` | torn down mid-run — closed as not planned |
  | `sssf:follow-up` | this run re-executes a run record whose previous session failed; body links `Follow-up to #N` |

- `SSSF_ISSUES=0` disables everything (named skip in the execute output).
- Vendored mode (no `app.repo`) skips with a named message — issues live in the app's
  own repo, and vendored mode has no separate one.
- `just sbx manage sync-issues` reconciles issues left open by a dead watcher /
  rebooted host, from the live VM or the teardown-pulled trace copy.
- **Credential boundary**: `gh` runs on the host only. The VM never sees a GitHub
  credential (same reason harvest uses bundles, not pushes) — all the tracker reads
  from the VM is the trace db over ssh.

## Verification (all on FRESH VMs, hello roster — `SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`)

Fresh mount per scenario: `just sbx mount <run>` then the scenario. Record the issue
URL/number of each in the final envelope.

- **(a) happy path**: `just sbx lifecycle execute run-a "add a /health endpoint…"`.
  Assert: issue exists in yhuangsh/hello-server titled with the instruction BEFORE the
  SDLC gets going (`gh issue view`), `sssf:running`; mid-run the review milestone
  comment appears; at completion the issue is closed **completed** with `sssf:accepted`
  and the final comment carries provenance, phase timeline, commits BASE..HEAD,
  tokens + $, outcome.
- **(b) failing run**: execute with prompt "change the server response AND add a test
  that deliberately fails". Assert: failure forensics comment (failing phase, gate
  detail, error verbatim, surviving-state note), closed **not planned**,
  `sssf:failed`.
- **(c) follow-up**: re-execute the SAME run record from (b). Assert: new issue with
  `Follow-up to #N` referencing (b)'s issue, label `sssf:follow-up`, and the run
  record's `prev_issue_number` set.
- **(d) teardown mid-run**: start an execute, wait until the SDLC is clearly running,
  then `just sbx lifecycle teardown`. Assert: issue closed not planned,
  `sssf:cancelled`, state-at-teardown note.
- **(e) disabled**: `SSSF_ISSUES=0 just sbx lifecycle execute …`. Assert: named skip
  line in output, no issue created, run record has no `issue_number`.
- **(f) vendored**: `just sbx lifecycle execute` with the default/template roster
  (`adws/adw_sssf_config/sssf.config.yaml`, no `app.repo`). Assert: named vendored
  skip, no issue.
- **(g) orphan reconcile**: start an execute, `kill` the watcher pid mid-run, let the
  SDLC finish, then `just sbx manage sync-issues`. Assert: the sweep closes the issue
  with the correct outcome and updates `issue_state` in the run record.
- **(h) credential boundary / secret hygiene**: on a VM from any scenario above,
  `ssh <vm>.exe.xyz 'env | grep -ci "GH_\|GITHUB"'` is 0 and
  `ssh <vm>.exe.xyz 'ls ~/.config/gh 2>/dev/null; which gh'` finds nothing
  credential-shaped; then host-side, dump every created issue body + comments
  (`gh issue view N --json body,comments`) and assert none contains any value from
  `.env` (script the check over the `.env` values; assert zero matches).

Teardown every scenario VM when done; the tree must be clean at the end.

## Out of scope

The factory repo, the parked items. No `adws/` changes. No push of anything to the app
repo beyond issues/labels/comments.

## Gotchas the builder must respect

- execute.just / teardown.just are IMPORTED into the root justfile: no `set` lines, no
  file-level just variables, everything bash-local. sync_issues.just follows
  list.just's header conventions; manage/mod.just owns its own `set` lines.
- `set -euo pipefail` in both recipes — every tracker call needs its `|| warn` guard.
- ssh-into-VM quoting: follow the existing printf-%q / heredoc patterns; never
  interpolate the prompt into a remote command string unquoted.
- The watcher is a HOST process (it needs gh). Only its trace reads go over ssh.
- `sessions.request` is truncated to 500 chars in the db — the VERBATIM instruction
  comes from the execute argument (passed to `open`), not from the db.
- Don't invent a `sqlite3` CLI dependency on the VM; use `python3` + stdlib sqlite3
  over ssh (observe.just/teardown precedent).
- gh title limit is 256 chars; truncate with `…` only when needed, full text always in
  the body.
