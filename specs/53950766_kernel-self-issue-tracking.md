# Plan — Kernel-self development: README section + issue tracking for vendored mode

## Goal

Two related changes:

1. **DOCS** — README.md gains a `## Developing sssf-sbx itself` section; `.env.sample` gains one comment line naming the shipped roster as the self-development config.
2. **ERGONOMICS** — vendored-mode runs (no `app.repo` in the roster) stop skipping issue tracking. The tracker resolves the issue target from THIS repo's `origin` (must be github.com; requires `gh` auth; otherwise a named skip, exit 0, exactly as today). Kernel-self runs get the full issue lifecycle in `yhuangsh/sssf-sbx` with a new auto-created `sssf:kernel` label and kernel-self provenance (no VM fields).

Making this real requires one supporting change the prompt's verification implies but does not name: **`just local mount` / `just local execute` currently hard-fail without `app.local_path`** ("roster has no app.local_path — run 'just local scaffold'…"). The dogfood proof (verification c) is a kernel-self run through `just local mount` + `just local execute` with the shipped vendored roster, so the local lane must learn the vendored kernel-self case: payload = this kernel tree.

## Current state (recon done — do not re-derive)

- `sandbox_mount/host/issue_tracker.py` — the tracker. `cmd_open` (line ~747) prints `issues: vendored mode — roster has no app.repo; skipping issue tracking` and returns 0. Labels live in the `LABELS` dict (auto-created by `ensure_labels` with `--force`). Provenance tables are built by `_provenance_rows(rec, chain, local=False)`; the `local=True` variant already omits VM fields. `_is_local(rec)` keys off `vm_name == "local"`. `close`/`watch`/`update`/`harvest` resolve the repo from the record's `issue_url` (`_repo_from_record`), so only `open` needs the target-resolution change; the close path needs the kernel flag only for provenance/commits/harvest wording.
- `just/sandbox/lifecycle/execute.just` — lines ~91-117: when the roster awk finds no `app.repo`, it sets `ISSUES_ON=0` and echoes `→ issues: vendored mode (no app.repo) — skipping issue tracking`. This pre-skip must go; the tracker itself becomes the single source of the vendored decision.
- `just/local.just` — `mount` exits 1 when `app.local_path` is empty; `execute` resolves `LOCAL_PATH` from `app.local_path` only; `doctor` FAILs when `app.local_path` is unset. `execute`'s tracker block already calls `open --local` / `close --local` unconditionally (no vendored pre-skip) — it needs no tracker-plumbing change, only the payload resolution change.
- `adws/adw_sssf_config/sssf.config.yaml` — the shipped roster. Vendored: no `app.repo`, no `app.local_path`; `app.path: apps/your-app` (a placeholder dir that does not exist). `just sbx mount`'s vendored preflight (`just/sandbox/mount.just` lines ~34-42) fails when `app.path` is not an existing directory, so the VM-isolated kernel-self lane is not mountable today.
- Vendored payload resolution for the chains is already correct: `adws/adw_modules/git_helper.py::payload_root` falls back to the factory root when there is no `local_path`; `run_record.state_root()` returns `None` in vendored mode so run state stays in kernel-owned `.sandbox/` + `adws/adw_data/`; `issue_tracker._trace` reads the host db at `REPO_ROOT / <roster observability.db>` for local records when the state root is `None`. None of that changes.
- `just adw prompt "<text>"` exists (`just/adws.just` line 36 → `adws/adw_prompt.py`): phases `engineer(request)` → `agent(prompt)`, default agent `builder`, no commit phase — the dogfood sentence lands as an uncommitted edit on the run branch.
- `run_record.py` has a closed schema; `get RUN_ID <field>` prints the field value (empty when unset). Existing fields suffice — no schema change.
- This repo's origin: `https://github.com/yhuangsh/sssf-sbx.git` (github.com — kernel-self tracking resolves here).
- `.env` currently has `# SSSF_CONFIG=...` commented out; the dogfood must `export SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml` inline (do not edit the operator's `.env`).

## Changes

### 1. `sandbox_mount/host/issue_tracker.py` — vendored mode resolves the kernel's origin

- **New label** in `LABELS`: `"sssf:kernel": ("8250df", "SSSF kernel self-development run (vendored mode)")`. `ensure_labels` auto-creates it with the rest.
- **New helpers**:
  ```python
  def _parse_github_origin(url: str) -> str:
      """'owner/name' from a github.com remote URL (https or ssh), else ''."""
      m = re.match(r"^(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?$",
                   (url or "").strip())
      return f"{m.group(1)}/{m.group(2)}" if m else ""

  def _kernel_origin_repo() -> tuple[str, str]:
      """(repo, skip_reason): this repo's origin as owner/name when it is a
      github.com remote; else ('', reason) for the named skip."""
      r = subprocess.run(["git", "remote", "get-url", "origin"],
                         capture_output=True, text=True, cwd=REPO_ROOT)
      url = (r.stdout or "").strip()
      if r.returncode != 0 or not url:
          return "", "this repo has no 'origin' remote"
      repo = _parse_github_origin(url)
      if not repo:
          return "", f"origin '{url}' is not a github.com remote"
      return repo, ""
  ```
  Keep `_parse_github_origin` a pure function so the non-github skip is demonstrable without touching this repo's git config.
- **`_is_kernel(rec)`**: True when `_repo_from_record(rec)` (or, at open time before the record has an issue, the freshly resolved origin repo) equals `_kernel_origin_repo()[0]`. Used by the close/final-comment path to pick kernel provenance; best-effort, False on any error.
- **`cmd_open`**: when the roster's `app.repo` is empty, resolve via `_kernel_origin_repo()`. On a skip reason print the named skip and return 0:
  `issues: vendored mode (kernel-self) — <reason>; skipping issue tracking`
  On success set `kernel = True`, use that repo, and add `--label sssf:kernel` to the create argv (in addition to `sssf:running`, and `sssf:local` when local). The existing `gh is not authenticated` named skip stays as-is and covers the unauthenticated case.
- **Provenance**: `_provenance_rows` and `_open_body` gain a `kernel` flag. Kernel rows (kernel wins over local when both): run id, `mode: vendored (kernel-self — the payload is this repo)`, `lane: host (just local)` only when local, roster, factory sha, `kernel HEAD (base)` = `commit_sha`, chain, created. No VM fields, no payload/local_path row. `_final_comment` derives the flag via `_is_kernel(rec)`.
- **`_commits`**: in the `_is_local` branch, when `_local_path_quiet()` is empty and the run is kernel-self, run the `git log <base>..HEAD` against `REPO_ROOT` instead of returning `[]`.
- **`_harvest_status`**: local branch — when kernel-self, say the commits are on branch `local/<run-id>` in this kernel repo (no bundle), instead of printing `<local_path>`.
- **Module docstring**: update the "a roster with no `app.repo` (vendored mode) skips" sentence to describe origin resolution + the named skips.

### 2. `just/sandbox/lifecycle/execute.just` — drop the vendored pre-skip

- Delete the `APP_REPO_ISSUES` awk block and the `→ issues: vendored mode (no app.repo) — skipping issue tracking` echo. `SSSF_ISSUES=0` remains the only host-side skip.
- After the `open` call, gate the watcher on an issue actually existing (the tracker may have named-skipped): set `ISSUES_ON=0` when `"$RR" get {{RUN_ID}} issue_number` comes back empty. This keeps a skipped run from spawning a useless watcher (`watch` already no-ops without an `issue_number`, so this is hygiene, not correctness).
- Update the header comment block (lines ~22-28) and the inline comment: vendored kernel-self runs now track into the kernel repo's own github.com origin (label `sssf:kernel`); the tracker owns the decision and the named skips.

### 3. `just/local.just` — kernel-self vendored support in the local lane

- **`mount`**: when the roster has neither `app.repo` nor `app.local_path`, this is kernel-self vendored mode — `LOCAL_PATH="$KERNEL_ROOT"`. In that mode: skip the outside-kernel check (the kernel IS the payload here), skip clone-if-missing, skip the manifest check (the kernel root has no `sssf.app.yaml`), skip the `.gitignore` arming block (state stays in kernel-owned `.sandbox/` + `adws/adw_data/`), keep `ensure_trace_db` (idempotent against the roster's `observability.db` = `adws/adw_data/sssf.db`), keep the clean-tree requirement, create/switch branch `local/<run-id>` in the kernel repo, and write the run record as today (`vm_name=local`, `commit_sha` = kernel HEAD, `factory_sha` = kernel HEAD). The mount summary should say `payload: <kernel root> (kernel-self, vendored)`.
- **`execute`**: same resolution — empty `app.repo` AND empty `app.local_path` → `LOCAL_PATH="$(pwd -P)"` (the kernel root). The rest (branch check, `open --local`, foreground chain, `close --local`) is unchanged; the tracker adds the `sssf:kernel` label and kernel provenance itself.
- **`doctor`**: when the roster is vendored with no `local_path`, print `ok    kernel-self (vendored) — payload is this tree` instead of the `FAIL app.local_path set` line.
- Update the header comment's roster example with one line noting the kernel-self vendored case.

### 4. `adws/adw_sssf_config/sssf.config.yaml` — make the shipped roster mountable kernel-self

- Change `app.path: apps/your-app` to `path: .` and reword the app-block comment: in kernel-self vendored mode the payload is this tree (path `.` = repo root); to arm an external app instead, copy this roster and set `repo:`/`ref:` (target mode) or point `path` at a vendored app dir. Verified against the consumers: `just/sandbox/mount.just` preflight (`[ -d . ]` passes), `fill.just` vendored branch never uses `APP_PATH`, `provision.sh` treats `.` as repo root and skips a missing manifest, `setup.just` gate A's porcelain filter `?? ./` never matches (harmless), `git_helper.payload_root` ignores `app.path` in vendored mode.

### 5. `README.md` — new section + consistency edits

- **New `## Developing sssf-sbx itself` section**, appended after the `## Local development — just local` section (which currently ends the file). Concise; cover exactly:
  - Lead: the kernel is its own first-class app via VENDORED mode — no `app.repo` means the payload is this tree.
  - Setup: clone; `cp .env.sample .env` and set the LLM keys; `SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml` — the shipped roster IS the self-development config, not a template to copy.
  - The two lanes:
    - **Host-instant**: `just adw sdlc "…"` directly, or the tracked variant `just local mount <id>` → `just local execute <id> sdlc "…"` → `just local ui` (run branch `local/<id>` in this repo).
    - **VM-isolated**: `just sbx mount <id>` → `just sbx lifecycle execute <id> "…"` → `just sbx manage harvest <id>` — the kernel develops itself on a disposable VM and harvest bundles the commits home.
  - The provenance rule: kernel-self runs MAY add `specs/` + `app_docs/` in this repo — here the kernel IS the project. App runs must never populate them (their state root lives at the payload).
  - Issue tracking pointer: kernel-self runs open/close issues in this repo's own GitHub origin (`yhuangsh/sssf-sbx`) labeled `sssf:kernel` — the project's public development log; see Session tracking below. `SSSF_ISSUES=0` still disables; a non-github.com origin or missing `gh` auth is a named skip.
- **Consistency edits** in the existing `### Session tracking (GitHub issues)` subsection:
  - Replace "Target mode only: a vendored roster has no separate app repo and skips with a named message." with the new behavior (vendored kernel-self resolves this repo's github.com origin; named skip when there is no origin, it is not github.com, or `gh` is unauthenticated).
  - Replace the bullet "Vendored mode (no `app.repo`) also skips with a named message — issues live in the app's own repo, and vendored mode has no separate one." accordingly.
  - In the `Which commands need SSSF_CONFIG` table, the `just local execute` row's "the issue tracker reads `app.repo`" becomes "the issue tracker reads `app.repo` (or this repo's origin in kernel-self vendored mode)".
  - Do NOT restructure anything else; keep edits surgical.

### 6. `.env.sample` — one comment line

In the `SSSF_CONFIG` block, add ONE comment line, e.g.:
`# Developing sssf-sbx itself? The shipped roster IS the self-development config: SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml`

## Out of scope

Everything not listed: no changes to `run_record.py`'s schema, no changes to target-mode tracker behavior, no orchestrator-skill cookbook updates, no `app_docs/` write-up (the chain's document phase may add one under the kernel-self provenance rule).

## Verification (all five required, real runs — no dry runs)

Ordering constraint: the dogfood run (c) creates and switches to branch `local/<id>` in THIS repo and requires a clean tree, so it runs AFTER the chain's commit phase has landed changes 1-6 on `main`. Only the chain's commit-owning phases perform the git mutations (branch create/switch/merge); the dogfood's README sentence lands uncommitted (the `prompt` chain has no commit phase) on `local/<id>` — the commit phase then brings it to `main` (merge or cherry-pick) and leaves the tree clean on `main`. `just local close <id>` closes the run record afterwards.

**(a) README + commands.** The new section exists; every command it names is verified against the repo (`just --list`, `just --list adw`, `just --list sbx`, `just --list local`; the recipes exist and the roster path resolves). `.env.sample` line present (`grep`).

**(b)** covered by (a)'s grep.

**(c) Dogfood proof (kernel-self, host-instant lane):**
```sh
export SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml
just local mount <id>            # kernel-self: payload is this tree, branch local/<id>
just local execute <id> prompt "add one sentence to the README section you just wrote, noting issue tracking now covers kernel-self runs"
```
Then prove the issue lifecycle: `gh issue list --repo yhuangsh/sssf-sbx --label sssf:kernel` shows it; the issue opened with `sssf:running` + `sssf:local` + `sssf:kernel`, carries kernel-self provenance (no VM fields), and is closed as completed with `sssf:accepted` and the final outcome comment. The `sssf:kernel` label was auto-created by the run.

**(d) Sandbox regression (target mode unchanged):** with `SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`, `just sbx mount <id2>` + `just sbx lifecycle execute <id2> "<trivial prompt>" "" prompt` — an issue opens in `yhuangsh/hello-server` with the VM provenance fields exactly as before and closes with the outcome; then `just sbx lifecycle teardown <id2>`. If exe.dev is unavailable in this environment, the fallback demonstration is a hello-roster `just local mount`/`execute` (local_path payload) showing the issue in hello-server with `sssf:local` and NO `sssf:kernel`, plus a diff read showing the target-mode code path untouched — report which was demonstrated.

**(e) Named skips still named:**
- `SSSF_ISSUES=0`: `SSSF_CONFIG=adws/adw_sssf_config/sssf.config.yaml SSSF_ISSUES=0 uv run sandbox_mount/host/issue_tracker.py open <id> --instruction probe` → prints the disabled skip, exit 0.
- non-github origin (never touch this repo's git config — use a throwaway copy): `git clone --quiet . /tmp/sssf-nongh && git -C /tmp/sssf-nongh remote set-url origin https://gitlab.com/x/y.git`, create a run record there, run the tracker `open` from the copy with the vendored roster → prints `issues: vendored mode (kernel-self) — origin 'https://gitlab.com/x/y.git' is not a github.com remote; skipping issue tracking`, exit 0. (Also exercise the no-origin case with `git remote remove origin` in the same throwaway.) Clean up `/tmp/sssf-nongh`.

**Done means:** (a)-(e) demonstrated, all changes landed by this chain, `git status` clean on `main`.
