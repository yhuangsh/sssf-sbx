# Plan: LOCAL payload mode — the `just local` namespace

## Goal

Add a non-sandboxed development lane that runs the **full sssf workflow** (same
ADW chains, gates, GitHub-issue tracking, scaffolding) **on the host**, against a
**local clone of the app** — no VM, no exe.dev, no detachment. The lane lives in a
new just namespace `local` with recipes: `scaffold`, `mount`, `execute`, `ui`,
`doctor`, `orch`.

Mental model: identical workflow to the sandbox lane; the payload is on your
machine. Tradeoffs (to be stated honestly in the README): no disposable isolation,
no VM gates, instant + $0, commits land directly on the local run branch, push
when ready.

The sandbox lane (`just sbx …`) must remain byte-for-byte behaviorally unchanged.

## Files to touch

| file | change |
| --- | --- |
| `adws/adw_modules/data_types.py` | `AppConfig` gains `local_path: Optional[str] = None` |
| `adws/adw_modules/git_helper.py` | `payload_root()` new precedence + kernel-inside named error |
| `adws/adw_sssf_config/sssf.hello.config.yaml` | commented `local_path:` example in the `app:` block (this file is the scaffolder's TEMPLATE) |
| `adws/adw_sssf_config/sssf.config.yaml` | same commented `local_path:` example in its `app:` block |
| `justfile` | register `mod local 'just/local.just'` |
| `just/local.just` | **NEW** — the whole namespace |
| `sandbox_mount/host/scaffold.py` | `--preset local\|sandbox` flag (default `sandbox`) |
| `sandbox_mount/host/issue_tracker.py` | local-mode flag: `sssf:local` label, VM fields omitted, local trace/commit reads |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md` | **NEW** cookbook for `just local orch` |
| `README.md` | new `## Local development — just local` section; SSSF_CONFIG table rows; scaffold section mention |

No new Python host scripts: `mount`/`doctor` are bash recipes in `just/local.just`
reusing `require_sssf_config.sh`, `roster_keys.sh`, `run_record.py` — the same
pattern as `just/sandbox/mount.just` and `just/sandbox/manage/mod.just`.

---

## 1. Payload resolution — `git_helper.payload_root()`

### `adws/adw_modules/data_types.py`

In `AppConfig` (line ~346), add one field with a comment:

```python
local_path: Optional[str] = None  # LOCAL mode: existing clone of the app on the host; wins over repo/path
```

Update the class docstring to name the three modes: local (host clone), target
(`repo`+`path`, VM), vendored (factory clone).

### `adws/adw_modules/git_helper.py`

Rewrite `payload_root(app_cfg, factory_root)` with this precedence, updating the
docstring:

1. **`local_path` set** → expand `~`, resolve:
   - If the resolved path is **inside `factory_root`** (use
     `resolved.is_relative_to(factory_root.resolve())`, Python ≥3.9 ok) → raise
     `RuntimeError` with a **named** error, e.g.
     `payload_root: app.local_path '<path>' is inside the kernel tree '<root>' — the kernel is never the payload of an app run; point local_path at a clone OUTSIDE the kernel`.
     This check fires whether or not the path is a git repo — pointing into the
     kernel is always the mistake.
   - Else if it is an existing git repo (`is_repo()`) → return it.
   - Else (set but missing/not a repo) → **fall through** to step 2. Cloning is
     the mount's job, not the resolver's; `payload_root` only resolves.
2. **`repo` set** and `<factory_root>/<app.path>` is an existing git repo → return
   it (today's target mode, unchanged).
3. Else → `factory_root` (vendored, unchanged).

Callers (`adws/adw_plan_build.py:27`, `adw_simple_sdlc.py:68`, `changes.py:59`)
need no changes — the RuntimeError propagates and fails the chain with the named
error, which is the intended behavior for (f).

### Roster templates

In both `adws/adw_sssf_config/sssf.hello.config.yaml` and
`adws/adw_sssf_config/sssf.config.yaml`, add to the `app:` block (keeping the
flat two-space style the awk parsers rely on):

```yaml
  # local_path: ~/projects/<app>   # LOCAL mode: an existing clone of app.repo on
                                   # the host. Set AND a git repo -> payload_root
                                   # resolves here (host runs, `just local`); it
                                   # must live OUTSIDE this kernel tree.
```

(Commented out — hello stays a sandbox roster; verify (g) depends on that.)

**Note on agent cwd:** agents are spawned with `cwd=run.repo_root` (the kernel
root) and `permissions.py` snapshots only the kernel tree. In target mode the
payload is the subdirectory `<kernel>/<app.path>`; in LOCAL mode it is an
absolute path outside. That is acceptable: the payload is its own git repo, the
run branch + commits are the audit, and `protected_files` still guards the
kernel machinery the agents can see. Do NOT try to extend permissions.py into
the payload — out of scope. The `mount` recipe prints the resolved payload path
so the human/orchestrator can steer agents at it.

---

## 2. `just/local.just` — NEW module

Register in the root `justfile`, right after the `mod sbx` block, mirroring its
comment style:

```just
# local development: the full sssf workflow on the host, payload in a local clone.
# NOT the factory repo's local.just — this kernel's `local` is the local dev lane.
mod local 'just/local.just'
```

`just/local.just` header (module inherits nothing — repeat the settings with one
`..`, like `just/adws.just`):

```just
set working-directory := '..'
set positional-arguments
set dotenv-load
```

Recipes:

### `default`

```just
default:
    @just --list local
```

### `scaffold REPO=''`

Thin entry over the shared scaffolder with the local preset (see §3):

```just
# interactively scaffold a GitHub app repo + roster for LOCAL development (clone on the host, no VM)
scaffold REPO='':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{REPO}}" ]; then
        exec uv run sandbox_mount/host/scaffold.py --preset local "{{REPO}}"
    else
        exec uv run sandbox_mount/host/scaffold.py --preset local
    fi
```

### `mount RUN_ID`

Host-side arming + payload prep, all bash, mirroring `just/sandbox/mount.just`'s
awk idiom:

1. `ROSTER=$(sandbox_mount/host/require_sssf_config.sh)` — the shared guard; a
   missing SSSF_CONFIG fails with THE named error.
2. awk-parse the `app:` block for `repo`, `ref`, `path`, `manifest`, and the new
   `local_path` (same awk shape as mount.just's `repo:`/`path:` extraction, one
   more pattern). Expand a leading `~` in bash:
   `LOCAL_PATH="${LOCAL_PATH/#\~/$HOME}"`.
3. Resolve the payload: `local_path` if set, else error
   (`[local mount] roster has no app.local_path — run 'just local scaffold' or add local_path: to the app: block`). **Refuse if it resolves inside the kernel**
   (same rule as payload_root; `case "$(cd …)"` realpath-prefix check against the
   justfile directory).
4. **Clone-if-missing:** if `local_path` is not an existing git repo
   (`git -C "$LOCAL_PATH" rev-parse --git-dir` fails):
   - require `app.repo` set, else named error (nothing to clone from);
   - `git clone "$APP_REPO" "$LOCAL_PATH"` (default branch; if `ref` set,
     `git -C "$LOCAL_PATH" checkout "$ref"`).
5. **Validate** (named errors, non-zero exit):
   - manifest present at `<payload>/<manifest>` (default `sssf.app.yaml`);
   - working tree clean: `git -C "$LOCAL_PATH" status --porcelain` empty, else
     error naming the dirty tree (the run branch must start clean).
6. **Run branch:** if `sbx/<RUN_ID>` exists → `git -C … switch sbx/<RUN_ID>`,
   else `git -C … switch -c sbx/<RUN_ID>`.
7. **Run record** (schema already tolerant — `vm_name` is a free string):
   - `sandbox_mount/host/run_record.py create {{RUN_ID}}` (if it already exists,
     reuse it — same retry shape as the sandbox phases);
   - `set {{RUN_ID}} vm_name=local commit_sha=$(git -C "$LOCAL_PATH" rev-parse HEAD) factory_sha=$(git rev-parse HEAD)`;
   - `tag` stays unset.
8. Print the mounted banner: payload path, branch, and the follow-ups
   (`just local execute {{RUN_ID}} sdlc "<prompt>"`, `just local ui`,
   `just local doctor`).

### `execute RUN_ID CHAIN PROMPT`

FOREGROUND — the user watches live; no nohup, no watcher, no run.log.

1. Guard: run record exists and `vm_name` is `local`
   (`run_record.py get {{RUN_ID}} vm_name`); resolve `ROSTER` via
   `require_sssf_config.sh`; re-derive the payload path exactly as `mount` does
   and verify `sbx/{{RUN_ID}}` is the checked-out branch (named error otherwise —
   "run `just local mount {{RUN_ID}}` first").
2. **Issue hooks, exactly like the sandbox lane** (best-effort, never fail the
   execute):
   - before: `uv run sandbox_mount/host/issue_tracker.py open {{RUN_ID}} --instruction "{{PROMPT}}" --chain "{{CHAIN}}" --local || warn`;
   - run the chain: `just adw {{CHAIN}} "{{PROMPT}}"` — this is the same recipe
     mapping the sandbox lane uses (`sdlc` → `adw_plan_build_test.py` etc.) and
     it already turns `SSSF_CONFIG` into `--config`. Capture its exit code
     WITHOUT `set -e` killing the recipe first (`set +e` around it or
     `if ! …; then`), because close must run either way;
   - after: `uv run sandbox_mount/host/issue_tracker.py close {{RUN_ID}} --outcome accepted|failed --local` chosen by the chain's exit code;
   - exit with the chain's exit code.
3. Quote the prompt through `{{ quote(PROMPT) }}` like execute.just does.

### `ui`

Serve the shipped visualizer against the local trace db (same mechanics as
`just/obs.just`'s `ui` recipe, pinned to the kernel db), and print the URL first:

```just
# serve the trace visualizer against the local adws/adw_data/sssf.db
ui:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "→ visualizer: http://localhost:5173 (db: adws/adw_data/sssf.db)"
    cd .claude/skills/sssf/apps/visualizer && bun install && \
      (SSSF_DB={{invocation_directory()}}/adws/adw_data/sssf.db bun run server/index.ts &) && bunx vite
```

### `doctor`

Local arming preflight, same ok/FAIL shape as `sbx manage doctor`:

- `chk "uv present" 'command -v uv'`, same for `bun` and `just`;
- `ROSTER=$(sandbox_mount/host/require_sssf_config.sh)` — the named error IS the
  report when unset;
- `chk "roster provider keys set" 'sandbox_mount/host/roster_keys.sh'`;
- payload resolvable: `local_path` set AND (`local_path` is a git repo OR
  `git ls-remote "$APP_REPO"` succeeds — clone-if-missing can fix it);
- when `local_path` exists as a repo: manifest present at
  `<local_path>/<manifest>`, and tree clean (WARN not FAIL is fine for clean —
  but FAIL for a missing manifest);
- final `local doctor: OK|FAILED` line, exit code to match.

### `orch HARNESS SSSF_CONFIG_FILE`

One recipe, `HARNESS` is `cc` or `pi` — keeping the orchestrator boot INSIDE the
local module (no submodule). Body mirrors `just/sandbox/orch/mod.just`
(validate → absolutize via cd/pwd → `export SSSF_CONFIG` → awk app: block → boot
banner → launch), with exactly these deltas:

- kickoff prompt reads the NEW cookbook:
  `Read and execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md, then the cookbook .claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md. SSSF_CONFIG is already exported and names your roster: $ROSTER. Every roster-consuming just command uses it — do not set or override it.`
- banner also prints `app.local_path` (one more awk line) and says harness
  `local/cc` / `local/pi`;
- **pi session id prefix is `local-`** (same derivation: strip `sssf.`/
  `.config.yaml`, sanitize, fallback to full basename) — sbx keeps `orch-`, so a
  user running both orchestrators for the same app never shares a session;
- cc launch: `claude --dangerously-skip-permissions "<kickoff>"`, and the banner
  prints the same `--continue` resume note as sbx orch;
- reject any `HARNESS` other than `cc|pi` with a usage error.

---

## 3. Scaffolder — `sandbox_mount/host/scaffold.py --preset local|sandbox`

One implementation, two entries. `just/sandbox/scaffold.just` is UNCHANGED (its
call `uv run sandbox_mount/host/scaffold.py [REPO]` keeps the default preset
`sandbox`, byte-identical behavior to today — verify (g) covers this).

Changes:

1. **Argument parsing:** accept `--preset local|sandbox` (default `sandbox`)
   before the optional `owner/name`. A tiny hand-rolled parse is fine (two args
   max); keep `main(argv)`'s `prefill` semantics.
2. **Local preset deltas** (guard each on `preset == "local"`):
   - After the runtime/serve/checks questions, ask
     `local path for the clone` with default `~/projects/<name>` (the mode
     question is skewed: sandbox preset never asks). Expand `~` for use but
     write the path as answered (or expanded — pick expanded, absolute, so the
     roster is unambiguous).
   - After the repo exists (create or adopt): `git clone` the repo into
     `local_path` when it isn't already a git repo (`gh repo clone owner/name
     <local_path>`; reuse the `run()` helper). If it already is a repo, say so
     and skip. Store the absolute path.
   - `write_roster()` gains a `local_path: str | None = None` parameter; when
     set, the generated `app:` block includes
     `  local_path: <abs path>      # LOCAL mode payload (just local …)` —
     flat two-space key, and the expected-values parse-back check includes it.
   - Finish banner: print
     `  3. mount:         just local mount <run-id>` instead of the `just sbx`
     trio when preset is local (keep steps 1–2: SSSF_CONFIG, then
     `just local doctor` for the preflight step).
3. Everything else — the summary gate, manifest validation, private-repo token
   flow, roster collision prompt — is shared and unchanged. (`APP_REPO_GIT_TOKEN`
   is VM-clone machinery; the local preset doesn't need it, but leave the check
   untouched for private repos in the shared path — harmless, and the sandbox
   lane may still be used for the same roster.)

---

## 4. Orchestrator cookbook — `.claude/skills/sssf-sandbox-orchestrator/cookbooks/local_mode.md` (NEW)

Same shape as `focus_on_app.md` (booted-by line, the SSSF_CONFIG working rule,
orient on the app) but **no VM vocabulary** — drive:

```bash
just local doctor                     # preflight
just local mount <run-id>             # clone-if-missing, run branch, run record
just local execute <run-id> sdlc "<prompt>"   # foreground — watch it live
just local ui                         # the trace visualizer
```

State the local truths: the payload is the clone at `app.local_path`; the run
branch is `sbx/<run-id>`; commits land there directly and the human pushes when
ready; issues open/close exactly like the sandbox lane with the `sssf:local`
label; there is no teardown — `git switch main` in the payload is the cleanup.
Point at `README.md → Local development` for the tradeoffs.

---

## 5. Issue tracker — `sandbox_mount/host/issue_tracker.py`

Everything best-effort stays; the sandbox lane is unchanged.

1. **Label:** add `"sssf:local": ("0075ca", "SSSF session ran on the host (local mode)")`
   to `LABELS` — `ensure_labels` already auto-creates with `--force`.
2. **Flag:** add `--local` to the `open`, `close`, and `watch` subparsers. Also
   auto-detect: a run record with `vm_name == "local"` is a local run (helper
   `_is_local(rec, args)` — explicit flag OR record). The local execute recipe
   passes `--local` explicitly; the record check makes `sync`/manual closes right.
3. **open (local):** add `--label sssf:local` alongside `sssf:running` (and
   `sssf:follow-up` when applicable).
4. **Body rendering (local):**
   - `_provenance_rows(rec, chain, local=…)`: omit the `vm`/`vm tag` rows (or
     render `payload: <local_path>` instead — read `local_path` from the roster
     via an extended `_app_config()`; keep the sandbox call sites' output
     byte-identical by defaulting `local=False`);
   - `_failure_forensics` surviving-state line: local variant says the payload
     clone at `<local_path>` on branch `sbx/<run-id>` survives; no VM mention;
   - `_harvest_status`: local variant — `local mode — commits are on branch
     sbx/<run-id> in <local_path>; push when ready (no bundle)`.
5. **Trace + commits (local):** in `_trace`, when local, read the HOST db
   directly: `_read_db(str(REPO_ROOT / "adws" / "adw_data" / "sssf.db"), since,
   adw)` — never ssh to `local.exe.xyz` (today a `vm_name` of `local` would try
   exactly that and fall through to a missing artifact copy). In `_commits`,
   when local: `git -C <local_path> log --format='%h %s' <commit_sha>..HEAD`
   instead of the ssh/harvest-cache paths.
6. Extend `_app_config()` to also return `local_path` (or add a sibling helper);
   keep the existing unpack sites working.

---

## 6. README.md

1. **New section `## Local development — just local`** (place it after the
   `## Use` section, before `### Session tracking`):
   - the mental model: same workflow — roster, chains, gates, issues, traces —
     but the payload is a clone on your machine and everything runs on the host;
   - the command flow: `just local scaffold` → `SSSF_CONFIG=…` →
     `just local doctor` → `just local mount <run-id>` →
     `just local execute <run-id> sdlc "…"` (foreground) → `just local ui`;
     orchestrator: `just local orch cc|pi <roster>`;
   - the honest tradeoffs vs the sandbox: no disposable isolation (the payload is
     your real clone — the run branch is the boundary), no VM gates
     (provision/setup/observe don't exist here), instant startup + $0 VM cost,
     commits land directly on `sbx/<run-id>`, you push when ready; issues are
     labeled `sssf:local`;
   - the one hard rule: `app.local_path` must point OUTSIDE the kernel tree —
     the kernel is never the payload of an app run (named error otherwise).
2. **SSSF_CONFIG table** (`## Which commands need SSSF_CONFIG`): add rows —
   `just local mount` (yes — preflight parses `app:`), `just local execute`
   (yes — the chain's `--config` comes from it), `just local doctor` (yes),
   `just local ui` (no — reads the local db only), `just local orch cc|pi
   <roster>` (the roster is the mandatory argument, exported for the session),
   `just local scaffold` (no — writes a roster).
3. **Scaffold section** (`### Scaffolding a new app: just sbx scaffold`): add
   that `just local scaffold` is the same scaffolder with the local preset —
   additionally clones the repo to `local_path` and writes it into the roster.

---

## Verification (all real, evidence in the envelope)

(a) **scaffold:** pick `NAME=sssf-local-test-$RANDOM_HEX`; drive
`printf '%s\n' … | just local scaffold "$NAME"` with piped answers (create,
public, bun, defaults, `local_path` under `/tmp` or `~/projects`). Assert: GitHub
repo created, clone exists at the chosen `local_path` as a git repo,
`sssf.$NAME.config.yaml` in the repo root contains `local_path:`, finish banner
prints `just local mount`. Keep the repo+clone for (b)–(e); afterwards
`gh repo delete "$GH_USER/$NAME" --yes` and remove the clone and the roster.

(b) **mount:** `SSSF_CONFIG=$PWD/sssf.$NAME.config.yaml just local mount <id>` →
preflight green; `git -C <local_path> branch --show-current` = `sbx/<id>`;
`run_record.py get <id> vm_name` = `local`, `commit_sha` set.

(c) **execute:** `just local execute <id> sdlc "add a /version endpoint returning {\"version\": \"0.1.0\"} plus a test"` — foreground, full SDLC green;
`git -C <local_path> log main..sbx/<id> --oneline` non-empty; the issue in the
test repo is closed as accepted and carries `sssf:local`
(`gh issue view … --json labels,state`).

(d) **orch resume:** derive `SID=local-<name>` exactly as the recipe does; two
non-interactive pi turns on that session id (turn 1 plants a fact, turn 2 recalls
it) proving the deterministic `local-` session continues. (The recipe itself is
interactive; the proof targets the id mechanism. Running
`just local orch pi <roster>` far enough to see the boot banner + exported
SSSF_CONFIG + `resume: … local-<name>` line, then Ctrl-C, is the recipe-level
evidence.)

(e) **ui:** launch `just local ui` backgrounded, `curl -sf http://localhost:5173`
(and the server port if it prints one), then kill it.

(f) **kernel immutability:** point a scratch roster's `local_path` inside the
kernel tree (e.g. `$PWD/tmp-payload`); call `payload_root` via
`uv run python -c …` and assert the named RuntimeError; also assert
`just local mount <id>` refuses with its named error.

(g) **sandbox regression:** with the hello roster
(`adws/adw_sssf_config/sssf.hello.config.yaml` — must still have NO local_path):
`just sbx manage doctor` green, `just sbx mount <id>` → gates A–E green, teardown;
plus a direct precedence probe: `payload_root` with no local_path still resolves
repo/target then factory (run the python one-liner for all three cases).

(h) **surface:** `just --list local` lists scaffold/mount/execute/ui/doctor/orch;
every command shown in the new README section has been executed in (a)–(e).

## Done means

(a)–(h) demonstrated with evidence in the envelope; feature + docs landed by this
chain's commit phase; throwaway repo deleted, throwaway clone and roster removed
from the tree; tree otherwise clean.

## Out of scope

The factory repo (its own `just/local.just` is a different file in a different
repo — do not touch it), parked items, and extending `permissions.py` into the
payload (see §1 note).
