# Resume + land `just sbx scaffold` — review, fix, full verification, cleanup

## Context you must know first

Run 3fc57d46's builder implemented the feature but its run was barred from
`adws/adw_sssf_config/` while testing, so verification never completed and its
test rosters were meant to be rolled back. **Actual current tree state (verified
during planning):**

- The feature survives **uncommitted**:
  - `sandbox_mount/host/scaffold.py` (untracked, full implementation)
  - `just/sandbox/scaffold.just` (untracked)
  - `just/sandbox/mod.just` (modified: import + THE SHAPE line)
  - `README.md` (modified: "Scaffolding a new app" section + directory-map rows)
- The prior run's test rosters were **NOT** rolled back — six
  `Add scaffolded roster for yhuangsh/sssf-scaffold-test-*` commits sit at HEAD
  (`1e9e3a6`..`3f39032`) and the six roster files are in the tree:
  `sssf.sssf-scaffold-test-{bun,node,tokno,tokyes,existing,existing2}.config.yaml`.
- The six matching GitHub repos **still exist** under `yhuangsh`
  (bun/existing/existing2 public; node/tokno/tokyes private). Prior-run cleanup
  never happened.
- `gh` is authenticated as `yhuangsh`. `APP_REPO_GIT_TOKEN` **is present** in
  the host `.env`.
- `adws/adw_sssf_config/sssf.meta8.config.yaml` (untracked) is **this session's
  own roster** — its header says "Delete when landed". Do NOT delete it mid-run
  and do NOT fold it into the feature work; note it in your report and leave the
  decision to the chain's commit phase / operator.
- `specs/3fc57d46_sbx-scaffold-feature.md` is the original spec — it is the
  review baseline. Read it first.

This run's roster authorizes exactly: the scaffolder script, its recipe,
mod.just wiring, README, and `adws/adw_sssf_config/` for generated test rosters.
The chain's commit phase owns the feature commit — you leave everything dirty.
`scaffold.py`'s own runtime roster commits (by design, requirement 5) are
expected and allowed: it is the tool under test exercising its specified
behavior.

## Step 1 — Review the implementation against the spec

Read `specs/3fc57d46_sbx-scaffold-feature.md` and audit
`sandbox_mount/host/scaffold.py`, `just/sandbox/scaffold.just`, the mod.just and
README diffs (`git diff`) line by line against it. Planning already did a full
pass; the implementation is essentially complete. Findings:

1. **Known deviation — exists/create shorthand.** Spec step 1.2 requires
   accepting `e`/`exists` and `c`/`create` (case-insensitive). The current code
   uses `ask_choice("repo exists or create-new", ("exists", "create"), "create")`
   which rejects bare `e`/`c`. Fix: accept the single-letter aliases (map
   `e→exists`, `c→create`), keep re-prompt on anything else.
2. Everything else matched on the planning pass: preflight (gh/auth/GH_USER/
   checkout probe, argv pre-fill), question order and defaults (serve on for
   bun/node, off for uv/none; port 4501 validated 1–65535; health_path must
   start with `/`; checks default test), summary + single `proceed? [y/N]` gate,
   create-new path (git init -b main, identity fallback,
   `gh repo create --source=. --push`), existing path (additions only, empty-ish
   detection via README*/LICENSE*/.gitignore, overwrite only on explicit `y`),
   manifest parse-back BEFORE any push, private-repo `.env` FILE check +
   `gh auth token` offer (never prints the token, confirms by line number) +
   exact-line fallback, roster write (hello template, flat two-space `app:`
   block, header comment, refuse-overwrite, parse-back assert, commits ONLY the
   roster file), final next-steps block (SSSF_CONFIG line, doctor, mount, lane
   reminder). Verify all of this yourself — the list above is a checklist, not a
   substitute.
3. While reviewing, confirm the roster `repo:` line's trailing
   `# scaffolded <visibility> repo` comment is safe for the awk parsers:
   `just/sandbox/mount.just` uses `print $2`, so `$2` is the URL — fine. Do not
   "fix" it away.

If you find other real deviations, fix them in place. Do not rewrite working
code for style. Do not touch `sssf.hello.config.yaml` (the template source).

## Step 2 — Clear the stale prior-run state (BEFORE any verification)

The fresh verification reuses the same repo/roster names, and scaffold refuses
to overwrite an existing roster — so the stale state must go first:

1. Delete all six GitHub repos:
   `gh repo delete yhuangsh/sssf-scaffold-test-<name> --yes` for
   `bun node tokno tokyes existing existing2`.
   Verify: `gh repo list yhuangsh --json name --jq '.[] | select(.name | startswith("sssf-scaffold-test"))'`
   returns empty.
2. `git rm` the six committed rosters
   `adws/adw_sssf_config/sssf.sssf-scaffold-test-*.config.yaml`. These deletions
   stay in the tree and ride the chain's commit. (The six `Add scaffolded
   roster` commits stay in history — accepted noise, per the original spec.)
3. Clean local leftovers: any `/tmp/sssf-scaffold-*` dirs and any /tmp clones of
   the test repos. Check `.sandbox/runs/` for stray `scaffold-*` records from
   the prior run and remove only those.

## Step 3 — Full verification suite (all of it, real repos, real mount)

Prereq: `SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml just sbx manage doctor`
is green (provider keys present). If doctor fails, STOP and report — do not edit
rosters to dodge a missing key.

**(a) create-new public bun, piped answers.** Pipe a here-doc into
`just sbx scaffold`: name `sssf-scaffold-test-bun`, create, public, bun, serve
defaults (Y, `bun --hot server.ts`, 4501, `/`), checks yes, proceed `y`.
Assert:
- `gh repo view yhuangsh/sssf-scaffold-test-bun --json isPrivate` → false;
- `gh api repos/yhuangsh/sssf-scaffold-test-bun/contents --jq '.[].name'` lists
  `sssf.app.yaml`, `server.ts`, `server.test.ts`, `package.json`, `.gitignore`;
- roster `adws/adw_sssf_config/sssf.sssf-scaffold-test-bun.config.yaml` exists
  and `git log --oneline -1 -- <roster>` is scaffold's commit;
- `git ls-remote https://github.com/yhuangsh/sssf-scaffold-test-bun.git`
  succeeds with NO credentials (public-clone proof).

**(b) create-new private node.** Same flow: `sssf-scaffold-test-node`, private,
node, serve defaults, checks yes. Assert:
- repo is private (`--json isPrivate` → true);
- token path: `APP_REPO_GIT_TOKEN` IS currently in `.env`, so scaffold must
  print its "is set in .env" line — capture that in the transcript. Do NOT add,
  remove, or print the token; `.env` must end byte-identical;
- clone proof: `git clone https://x-access-token:$(gh auth token)@github.com/yhuangsh/sssf-scaffold-test-node.git /tmp/scaffold-verify-node`
  succeeds, while unauthenticated
  `git ls-remote https://github.com/yhuangsh/sssf-scaffold-test-node.git` FAILS.
  (Keep the token out of logs — redirect/quiet the clone output.)

**(c) existing-repo, additions only.** Pre-seed:
`gh repo create yhuangsh/sssf-scaffold-test-existing --public`, clone to /tmp,
add `NOTES.txt` with known content (e.g. `pre-existing content — do not touch`),
commit, push. Run scaffold in `exists` mode, uv runtime, serve off (default for
uv), checks yes. Assert via `gh api repos/.../contents`:
- `NOTES.txt` present, content unchanged (fetch and compare);
- `sssf.app.yaml` added, skeleton files added (repo was empty-ish), `.gitignore`
  added;
- `git log` on the default branch shows the scaffold commit message
  `sssf-sbx scaffold: add manifest + skeleton for uv runtime`.

**(d) OUT-OF-BOX PROOF.** Using the roster from (a):

```sh
SSSF_CONFIG=adws/adw_sssf_config/sssf.sssf-scaffold-test-bun.config.yaml just sbx mount scaffold-proof-1
```

Must run arming preflight → create → fill → setup (gates A–E green) → observe,
ending with the app serving — observe's readback shows `200` for the scaffolded
bun server. Then:

```sh
SSSF_CONFIG=adws/adw_sssf_config/sssf.sssf-scaffold-test-bun.config.yaml just sbx lifecycle teardown scaffold-proof-1
```

If doctor/mount complains about provider keys for the hello-template providers,
STOP and report — do not edit the roster's model list to dodge a missing key.

**(e) invalid inputs rejected cleanly** (piped answers; assert re-prompt or
exit 1, and NO repo created):
- port `70000` then `abc` → both re-prompt (then feed `4501` and abort at the
  confirm gate with `n`);
- visibility `maybe` → re-prompts (then abort);
- `exists` against `yhuangsh/sssf-scaffold-test-does-not-exist` → exit 1 with
  the `APP_REPO_GIT_TOKEN` guidance message;
- also exercise the fixed `e`/`c` shorthand from Step 1 (e.g. `c` accepted for
  create) — can ride the same piped runs;
- `gh repo list` before/after proves the failing runs created nothing.

## Step 4 — Cleanup (mandatory)

1. `gh repo delete --yes` every fresh `sssf-scaffold-test-*` repo (bun, node,
   existing). Verify the account has none left.
2. Remove the fresh runtime-committed rosters
   `adws/adw_sssf_config/sssf.sssf-scaffold-test-*.config.yaml` from the tree
   (`git rm`) — the repos they point at are gone, so do not keep one "for the
   demo"; the README section + transcripts are the demo. Deletions ride the
   chain's commit.
3. Remove /tmp clones (`/tmp/scaffold-verify-*` etc.) and confirm
   `.sandbox/runs/` has no `scaffold-proof-*` records left (teardown in (d)
   should have handled it).
4. Confirm `sssf.hello.config.yaml` is byte-untouched (`git diff` shows nothing
   for it) and `.env` is unchanged.

## Final tree state (what the chain's commit phase will see)

- NEW: `sandbox_mount/host/scaffold.py` (executable bit set — check `git ls-files -s`
  / `stat` shows +x; chmod it if the prior run lost it), `just/sandbox/scaffold.just`
- MODIFIED: `just/sandbox/mod.just`, `README.md`
- DELETED: the nine `sssf.sssf-scaffold-test-*.config.yaml` rosters (six stale +
  three fresh; scaffold's runtime commits for the fresh ones remain in history —
  accepted noise)
- UNTOUCHED: `adws/adw_sssf_config/sssf.hello.config.yaml`, `.env`,
  `sssf.meta8.config.yaml` (still untracked — flag it in your report for the
  commit phase; its header says "Delete when landed")

## Guardrails

- Never print tokens. `gh auth token` output goes only into subprocess argv for
  the clone proof; redirect that command's output.
- Never overwrite an existing roster or `sssf.app.yaml` — scaffold itself
  enforces this; don't force it from outside either.
- All scratch (transcripts, logs) goes to `/tmp`, never the repo.
- You are barred from git ref mutations; scaffold.py's own roster commits during
  verification are the tool's specified behavior and are fine. Everything else
  stays dirty for the chain's commit phase.
- Done = (a)–(f) demonstrated with real repos and a real mount, evidence in your
  report, feature + README left for the chain to land, tree otherwise clean.

## Out of scope

Everything else: no changes to provision.sh / observe.just / quality.py /
mount.just, no factory-repo work, no README rewrites beyond the existing
scaffold section.
