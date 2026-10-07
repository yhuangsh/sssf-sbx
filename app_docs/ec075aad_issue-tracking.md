# Session tracking — one GitHub issue per ADW session, in the app's own repo

Every `just sbx lifecycle execute` now opens one GitHub issue in the roster's `app.repo` *before*
the detached SDLC launches, and closes it with the full audit record when the session ends. The
issue is the durable instruction → outcome trail that lives where the code does, instead of inside
the disposable sandbox. Target mode only — vendored mode skips with a named message because there
is no separate app repo to file into. The implementation is best-effort end to end: a tracker
failure warns and never fails mount/execute/teardown, and `SSSF_ISSUES=0` disables the whole feature.

## Why it matters

Until now the audit record of an ADW session lived in two places — `.sandbox/runs/<run-id>.json`
(the run record) and `.sandbox/runs/<run-id>-artifacts/...` (the teardown-pulled trace copy). Both
die with the host: a wiped `.sandbox/` loses the trail of what every session actually did and why.
With this change the same trail lives in the roster's `app.repo`, under five `sssf:*` labels
(`running` / `accepted` / `failed` / `cancelled` / `follow-up`), with comments carrying the
instruction, provenance, phase timeline, review verdicts, target run-branch commits `BASE..HEAD`,
tokens + $ cost, outcome reason verbatim, and harvest status. Anyone who can see the app repo can
see the trail without ever mounting a sandbox.

The second thing it nails down is the **credential boundary**. The VM never sees a `GH_TOKEN` or
`~/.config/gh` — exactly the same reasoning that has `harvest` move commits as a bundle rather
than a push. `gh` runs on the host against the engineer's own host credential store, and the
tracker's only VM contact is a read-only `ssh … python3` + stdlib `sqlite3` query against
`/home/exedev/app/adws/adw_data/sssf.db`.

## Where the change lives

- **`sandbox_mount/host/issue_tracker.py`** — *new*, 906 lines. A uv PEP-723 script (pyyaml only)
  that wraps the `gh` CLI and reuses `run_record.py` as its store. Five subcommands:
  - `open RUN_ID --instruction TEXT [--chain NAME]` — guards (SSSF_ISSUES=0 → named skip;
    no `app.repo` → named vendored skip; no `gh auth` → warn-exit). Detects follow-up
    (record's existing `issue_number` is closed with `sssf:failed` → new issue gets
    `sssf:follow-up` + `Follow-up to #N` in the body). Calls `ensure_labels` (idempotent via
    `--force`) and then `gh issue create --label sssf:running`. Records `issue_url`,
    `issue_number`, `issue_state=open`, and `prev_issue_number` into the run record.
  - `update RUN_ID --milestone NAME [--db PATH]` — appends ONE coarse milestone comment
    (`<!-- sssf:milestone:NAME -->` marker guards idempotency).
  - `close RUN_ID --outcome accepted|failed|cancelled [--db PATH] [--note TEXT]` — appends the
    final comment, removes `sssf:running`, adds `sssf:<outcome>`, closes the issue with
    `--reason completed` for accepted or `not planned` otherwise. Records `issue_state` into the
    run record. Idempotent: an already-closed issue just warns and reconciles `issue_state` from
    its current labels.
  - `watch RUN_ID --since ISO_TS` — the detached host loop. Polls every ~30s (cap 6h), matches
    the session by `started_at >= since` because the adw_id does not exist at launch. One
    milestone comment when a verification phase (`review%`/`test%`/`quality%`/…) reaches
    success; on session `status` success/fail, calls `close` with that outcome. Stops early
    if the run record's `issue_state` is already one of the closed values, or if it has been
    replaced by a follow-up.
  - `sync` — the backstop. Iterates every run record; for runs whose issue is still open,
    reads the trace (live VM, else `.sandbox/runs/<run_id>-artifacts/adws/adw_data/sssf.db`,
    else warns and skips) and closes the issue with the real outcome.

  Issue bodies pass through `redact()` before they leave the host, replacing every host env var
  value whose name matches `(KEY|TOKEN|SECRET|PASSWORD)` and whose length is ≥ 8 with
  `***REDACTED***`. Body content is assembled from the instruction, run metadata, trace rows,
  commit subjects, and error strings — never from `.env` — so the pass is the belt to the
  suspenders of never assembling content from `.env` in the first place.

- **`sandbox_mount/host/run_record.py`** — extends the closed `FIELDS` tuple with four
  keys, following the same sanctioned extension path used previously for `ports`:

  - `issue_url`         — `https://github.com/<owner>/<repo>/issues/<n>`
  - `issue_number`      — int (coerced via `_COERCE`)
  - `issue_state`       — `open | accepted | failed | cancelled` (the tracker's view)
  - `prev_issue_number` — int (coerced via `_COERCE`); the issue this run record's previous
                          execute opened, used for `Follow-up to #N` linkage.

  No other changes — `set` / `get` / `close` / `list` work unchanged, and unknown keys are still
  rejected (so the tracker can only write what is declared here).

- **`just/sandbox/lifecycle/execute.just`** — two hooks around the existing SDLC launch.
  - *Before* the detached SDLC: decide once whether this run gets an issue. `SSSF_ISSUES=0` →
    `→ issues: disabled (SSSF_ISSUES=0) — skipping issue tracking`. Otherwise parse the active
    roster (preferring host `$SSSF_CONFIG` when set, else the VM copy FILL shipped, using the
    same `app:`-block awk idiom as `mount`/`fill`/`teardown`/`harvest`); no `app.repo` →
    `→ issues: vendored mode (no app.repo) — skipping issue tracking`. If enabled, capture
    `SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)` *before* launch (the watcher matches the session by
    `started_at >= SINCE` because the adw_id is not known yet) and call
    `uv run issue_tracker.py open RUN_ID --instruction "$PROMPT" --chain "$ADW"`. The
    `|| echo "!! issue open failed …"` keeps the tracker best-effort.
  - *After* `pid` is recorded: spawn the watcher with the same three detachment pieces the SDLC
    uses — `nohup`, `> .sandbox/runs/<RUN_ID>.watcher.log 2>&1`, `< /dev/null` — but locally,
    because the watcher needs `gh`. `teardown` and `just sbx manage sync-issues` are the
    backstops if it dies.

  Header comment block now documents the contract: what opens when, the env var, the skip
  messages, and the "never fails the execute" guarantee.

- **`just/sandbox/lifecycle/teardown.just`** — new **step 2.5** between harvest (step 2) and
  destroy (step 3). After harvest so the commits section can read the bundle/cache, before
  destroy so a live VM can still answer trace queries. Reads `issue_number` from the record;
  if set and `SSSF_ISSUES != 0`, calls
  `uv run issue_tracker.py close RUN_ID --outcome cancelled --note "closed at teardown <ISO>;
  VM <name|gone>; harvest <ran|skipped>"`. `close` is idempotent (already-closed → warn, exit
  0), so the normal watcher-beat-teardown case costs one `gh` call. A failure prints the
  reconciliation command and the teardown continues. Header comment updated to mention 2.5.

- **`just/sandbox/manage/sync_issues.just`** — *new*, imported by `manage/mod.just`. The
  `sync-issues` recipe: `set -uo pipefail`, `cd {{justfile_directory()}}`, the same
  `SSSF_ISSUES=0` named-skip guard, then `uv run sandbox_mount/host/issue_tracker.py sync`.

- **`just/sandbox/manage/mod.just`** — adds `import 'sync_issues.just'` alongside the other
  two imports. Header comment paragraph rewritten to call out `sync-issues` as the one manage
  command that does write the run record (it reconciles `issue_state` for runs whose watcher
  died).

- **`README.md`** — new `### Session tracking (GitHub issues)` subsection immediately after
  the `## Use` loop, before the lane-mental-model follow-ons. Documents: what opens when,
  the state-label table, the `SSSF_ISSUES=0` and vendored skips, `sync-issues`, and the
  credential-boundary note.

- **`specs/ec075aad_issue-tracking.md`** — *new*, the proposal/spec itself. Not a feature
  file; documents the architecture, the file-by-file change list, the eight verification
  scenarios (a–h), and the gotchas the builder must respect.

## How to use or verify

For a normal run:

```bash
just sbx lifecycle execute my-run "add a /health endpoint …"
```

You should see, in the execute output, two new lines: the issue URL printed by `tracker open`
and the watcher's PID. Then `gh issue list --repo <app.repo> --label sssf:running` should show
your issue. Within ~30s of the SDLC's review phase completing, a milestone comment appears.
When the session ends, the issue closes as `completed` with `sssf:accepted` and a final
comment carrying the full audit record (instruction, provenance, phase timeline, reviews,
commits `BASE..HEAD`, cost, outcome, harvest status).

The eight verification scenarios from the spec are designed to exercise every code path on
fresh VMs against the hello roster (`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`,
`app.repo: https://github.com/yhuangsh/hello-server.git`):

- **(a) happy path** — succeed end to end → issue opened with the instruction as title,
  `sssf:running`, milestone comment appears, closed `completed` with `sssf:accepted`.
- **(b) failing run** — prompt crafted to fail (e.g. "change the response AND add a failing
  test") → failure forensics (failing phase, gate detail, error verbatim, surviving-state
  note), closed `not planned`, `sssf:failed`.
- **(c) follow-up** — re-execute the same run record from (b) → new issue with
  `Follow-up to #N` referencing (b)'s issue, label `sssf:follow-up`,
  `prev_issue_number` set in the record.
- **(d) teardown mid-run** — start an execute, `just sbx lifecycle teardown` while the SDLC
  is running → issue closed `not planned`, `sssf:cancelled`, state-at-teardown note in the
  final comment.
- **(e) disabled** — `SSSF_ISSUES=0 just sbx lifecycle execute …` → `→ issues: disabled
  (SSSF_ISSUES=0) — skipping issue tracking` in the output, no issue created, no
  `issue_number` in the record.
- **(f) vendored** — execute against the default/template roster with no `app.repo` →
  `→ issues: vendored mode (no app.repo) — skipping issue tracking`.
- **(g) orphan reconcile** — start an execute, `kill <watcher-pid>` mid-run, let the SDLC
  finish, then `just sbx manage sync-issues` → the sweep closes the issue with the correct
  outcome and updates `issue_state` in the record.
- **(h) credential boundary / secret hygiene** — on any VM from (a)–(g),
  `ssh <vm>.exe.xyz 'env | grep -ci "GH_\|GITHUB"'` returns 0, no `~/.config/gh` on the VM,
  no `gh` binary on the VM; then host-side, dump every created issue body + comments
  (`gh issue view N --json body,comments`) and assert no `.env` value appears in any of
  them.

Manual spot-checks at the gh CLI:

```bash
gh issue list --repo <app.repo> --label sssf:running      # sessions in flight
gh issue list --repo <app.repo> --label sssf:accepted     # succeeded
gh issue list --repo <app.repo> --label sssf:failed       # failed (failure forensics in final comment)
gh issue list --repo <app.repo> --label sssf:cancelled    # torn down mid-run
gh issue list --repo <app.repo> --label sssf:follow-up    # re-run of a failed run record
gh issue view <N> --repo <app.repo> --comments            # the full audit trail
```

Watch the watcher in flight:

```bash
tail -f .sandbox/runs/<run-id>.watcher.log
```

Force reconciliation at any time:

```bash
just sbx manage sync-issues
```
