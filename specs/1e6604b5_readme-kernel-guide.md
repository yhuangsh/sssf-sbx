# Plan: Rewrite README.md as the minimalist sssf-sbx arming guide

## Goal

Replace the placeholder `README.md` with a concise, marketing-free guide for a
developer who has cloned or vendored this kernel and wants their own project
riding sssf. **Touch `README.md` only.** Every command and field must match
this repo's own files — the verified facts below are the source of truth;
several of them CORRECT what the task prompt said (see "Corrections").

## Verified facts (checked against the repo — use these, not memory)

### Repo layout (top level)

`.claude/`, `.env` (gitignored, local), `.env.sample`, `.gitignore`, `adws/`,
`just/`, `justfile`, `LICENSE`, `README.md`, `sandbox_mount/`.

- Root `justfile`: `mod adw 'just/adws.just'`, `mod sbx 'just/sandbox/mod.just'`,
  `mod obs 'just/obs.just'`; `config := env_var_or_default("SSSF_CONFIG",
  "adws/adw_sssf_config/sssf.config.yaml")`.
- `just/adws.just` — in-sandbox ADW layer. Recipes: `prompt`, `ask`, `scout`,
  `plan`, `build`, `plan-build`, `build-test`, `build-review`, `quality`,
  `document`, `sdlc`, `plan-build-test-quality`, `simple-sdlc`. All run
  `uv run adws/adw_*.py --config {{config}}`.
- `just/obs.just` — `rosters`, `sessions`, `phases ADW_ID`, `tail ADW_ID`,
  `procs ADW_ID`, `kill ADW_ID`, `ui` (boots the visualizer: server :4600 +
  vite dev). Reads `adws/adw_data/sssf.db` via sqlite3.
- `just/sandbox/mod.just` — `mod lifecycle`, `mod manage`, `mod run`,
  `import 'mount.just'`. Namespace split is by credential: the exe.dev account
  never leaves the host, so a sandbox cannot mount sandboxes.
- `just/sandbox/mount.just` — `mount RUN_ID`: chains `lifecycle create → fill →
  setup → observe`. Stops at observe by design; teardown is never chained.
- `just/sandbox/lifecycle/` — six phases: `create`, `fill`, `setup`, `execute`,
  `observe`, `teardown`. `setup` streams `sandbox_mount/guest/provision.sh` over
  ssh stdin (host copy is authoritative) and then runs the **health gate with 5
  assertions A–E**: A git integrity, B pi current + `--list-models` non-empty,
  C every roster model answers through pi, D non-zero cost on a live call,
  E every roster provider has its env key. A failed gate leaves the VM up.
- `just/sandbox/lifecycle/execute.just` — signature:
  `execute RUN_ID PROMPT CONFIG="" ADW="sdlc" *EXTRA`. Runs detached
  (`nohup just --shell bash --shell-arg -c adw <ADW> <prompt> --config <cfg>`
  inside the VM), records the pid in the run record. CONFIG defaults to the
  per-sandbox `/home/exedev/sssf_config.yaml` shipped by FILL; a missing file is
  a hard failure. Watch hint printed by the recipe itself:
  `just sbx run cmd <id> 'tail -f run.log'`.
- `just/sandbox/lifecycle/teardown.just` — `teardown RUN_ID *FLAGS`:
  artifacts → harvest → destroy → close. `--no-harvest` is the only flag. A
  failed harvest ABORTS teardown (never destroys a VM whose commits were not
  pulled). Idempotent.
- `just/sandbox/manage/` — `doctor` (checks: ssh exe.dev reachable, run_record
  helper runs, provisioner present+executable, roster provider keys set, adw
  layer resolves), `list` (all runs + VM liveness), `harvest RUN_ID`.
- `just/sandbox/manage/harvest.just` — pulls the run branch `sbx/<id>` as a
  git bundle over `<base>..<branch>` into `.sandbox/runs/<id>.bundle`, verifies
  it, and fetches into `refs/sandbox/<id>` (vendored mode: the factory repo;
  target mode: a bare cache at `.sandbox/repos/<app>.git`). Never touches the
  working tree. The sandbox holds NO git credential — that is why bundle, not
  push. Not a phase; writes nothing to the run record.
- `just/sandbox/run/` — `cmd RUN_ID +CMD` (synchronous escape hatch,
  `ssh vm.exe.xyz "cd app && ..."`), `agent RUN_ID PROMPT` (resumable pi session
  inside the box, `--session-id` from the run record). Neither destroys VMs.
- `sandbox_mount/host/` — `run_record.py` (the only cross-phase state; get /
  set / list over `.sandbox/runs/<id>.json`), `roster_keys.sh` (checks every
  roster provider's env key is set), `runs_table.py` (formats `manage list`).
- `sandbox_mount/guest/provision.sh` — 9 steps, idempotent, **never apt**
  (~148 kB/s apt measured; CDN installs are ~1s). bun from bun.sh, just from
  just.systems, standalone Node 22 from nodejs.org into `~/.local/node`, pi
  installed at the npm `latest` dist-tag, then the app step is **manifest-driven**:
  reads `app.path`/`app.manifest` from `/home/exedev/sssf_config.yaml`, then the
  manifest's `runtime`, `install:`, `build:`; a declared runtime outside
  `bun|node|uv` (or missing on PATH) is a named failure, never an apt fallback.
  `runtime: none` / absent skips the runtime check. No manifest + package.json
  → `bun install` fallback. Also builds the visualizer (`bun install` +
  `bunx vite build`) and initializes the trace db.
- `adws/` — 12 chains `adw_*.py` (prompt, scout, plan, build, plan_build,
  build_test, build_review, quality, plan_build_test, plan_build_test_quality,
  simple_sdlc, document); `adw_modules/` runtime (`agent_pi.py`, `agent_cc.py`,
  `agents.py`, `runner.py`, `session.py`, `tracer.py`, `gates.py`, `quality.py`,
  `permissions.py`, `prompts.py`, `git_helper.py`, `changes.py`, `console.py`,
  `data_types.py`, `utils.py`); `adw_data/prompt_engineering/` +
  `adw_data/harness_engineering/`; `adw_sssf_config/` rosters
  (`sssf.config.yaml` default — vendored mode, `app: {path: apps/your-app,
  manifest: sssf.app.yaml}`; `sssf.hello.config.yaml` template — target mode,
  `app.repo: https://github.com/yhuangsh/hello-server.git`, `ref: main`,
  `path: target`, `manifest: sssf.app.yaml`).
- `adws/adw_modules/quality.py::_load_checks` — the manifest's `checks:` has
  **TWO supported shapes, both load**: a MAP of `name: [argv...]` (map entries
  get default `area: backend`, `operation: build`) and a LIST of
  `{name, area, operation, argv, timeout_seconds}`. Checks run with cwd = the
  app dir; argv may contain `{outdir}`. A manifest with no `checks:` yields no
  checks — the SDLC runs without the deterministic gate.
  **Note:** the comment block in `sssf.hello.config.yaml` claiming the map form
  raises TypeError is STALE — the code normalizes maps (lines ~84–91). The
  README documents the map form per the code.
- Roster `app:` block semantics (comments in both rosters, implemented in
  `fill.just`/`harvest.just`): `repo:`+`ref:` present = TARGET mode — FILL
  clones the app repo into `~/app/<path>` on the VM, the run branch and all ADW
  commits live on that clone, harvest bundles from it into a dedicated bare
  cache; the factory clone stays byte-identical. No `repo:` = VENDORED mode —
  the payload lives in the factory clone at `app.path`. `APP_REPO_GIT_TOKEN`
  only for private app repos (shipped stdin-only into `app/.env` 0600,
  ephemeral askpass, never in the remote URL, NEVER in a roster).
- `.env.sample` — allowlisted LLM provider keys (ANTHROPIC/OPENAI/OPENROUTER/
  GEMINI/GOOGLE/DEEPSEEK/ZAI/ZAI_CODING_CN/MOONSHOT/KIMI/MINIMAX/MINIMAX_CN/
  MISTRAL/XAI/GROQ/CEREBRAS/FIREWORKS/TOGETHER/BASETEN `_API_KEY`), which FILL
  copies to `app/.env` (0600) on each VM and whose REQUIRED set is derived from
  the active roster's `model: provider/id` entries (FILL fails fast naming
  missing ones); `APP_REPO_GIT_TOKEN` (optional, private app repos only);
  overrides `ENGINEER_NAME`, `PI_PATH`, `PI_MODELS_PATH`, `SSSF_CONFIG`.
- Visualizer: `.claude/skills/sssf/apps/visualizer/` — Vue + bun; booted by
  `just obs ui`; in-sandbox observe serves it on :4600 against
  `adws/adw_data/sssf.db`.
- `manage doctor` is the preflight: run before anything else.

### Corrections to the task prompt (the README must use the verified form)

1. **`just sbx lifecycle execute <id> <chain> "<prompt>"` is wrong.** Real
   signature: `just sbx lifecycle execute <run-id> "<prompt>" [config] [adw]`.
   The chain/ADW is the **4th** positional, not the 2nd, and defaults to
   `sdlc`. Correct examples:
   - `just sbx lifecycle execute myrun "add X"` (roster from the sandbox,
     chain `sdlc`)
   - `just sbx lifecycle execute myrun "add X" "" simple-sdlc` (empty config
     placeholder to reach the ADW argument)
2. **`just phases <id>` does not exist.** The recipe lives in the `obs`
   module: `just obs phases <adw_id>`, `just obs tail <adw_id>`. Also
   available: `just obs sessions`, `just obs procs <adw_id>`,
   `just sbx run cmd <run-id> 'tail -f run.log'`.
3. "gates A–E" belong to the **setup** phase (mount chains through it); fine to
   say mount runs the setup gate A–E.
4. `checks:` map form is fine (see quality.py note above) — ignore the stale
   TypeError caveat in the hello roster's comments.

## Files to change

**Only `README.md`** — full rewrite (currently a 3-line placeholder).

## README structure to write

Keep it tight — this is a kernel. No badges, no marketing. Suggested sections:

1. **`# sssf-sbx` + WHAT THIS IS.** Two layers in one repo: the **agent layer**
   (`adws/`: 12 `adw_*.py` chain scripts, `adw_modules/` runtime — quality,
   gates, permissions — plus `adw_data/` prompt/harness engineering and
   `adw_sssf_config/` rosters) and the **sandbox layer** (`just/sandbox/`
   mount chain create→fill→setup→observe on exe.dev VMs, plus execute,
   harvest, teardown; `sandbox_mount/` host run-record + roster-keys and the
   guest `provision.sh` streamed host-side at setup). One philosophy sentence:
   deterministic Python owns sequencing and gates; agents own judgement.
2. **DIRECTORY MAP.** Every top-level entry and its role: `justfile` (mods
   `adw` + `sbx` + `obs`; the `adw`/`sbx` split is by credential — the exe.dev
   account never leaves the host), `just/adws.just`, `just/obs.just`,
   `just/sandbox/` (`mount.just` chain; `lifecycle/` create-fill-setup-execute-
   observe-teardown; `manage/` doctor+list+harvest; `run/` agent+cmd lanes),
   `sandbox_mount/host/` (`run_record.py`, `roster_keys.sh`, `runs_table.py`),
   `sandbox_mount/guest/provision.sh` (node from nodejs.org + npm, pi at
   registry-latest, manifest-driven app deps, never apt), `adws/` (12 chains;
   `adw_modules/`; `adw_data/`; `adw_sssf_config/` rosters),
   `.claude/skills/sssf/apps/visualizer/` (trace UI, `just obs ui`, :4600),
   `.env.sample`, `LICENSE`.
3. **INTEGRATION.** Two modes:
   - **(a) TOOLBELT (recommended):** keep sssf-sbx as its own clone; the app
     stays an external git repo; a roster's `app:` block (`repo:` / `ref:` /
     `path:` / `manifest:`) points at it — FILL clones it into `~/app/<path>`
     on the VM, commits land on branch `sbx/<id>` there, harvest bundles into a
     bare cache under `.sandbox/repos/`. See the shipped template
     `adws/adw_sssf_config/sssf.hello.config.yaml` pointing at the public
     `hello-server` example. Files that matter: your roster copy + `.env`.
   - **(b) VENDORED:** copy `adws/`, `just/`, `sandbox_mount/`, `.env.sample`,
     and `.claude/skills/sssf/apps/visualizer/` into your own repo and set the
     default roster's `app.path` to your app dir (no `repo:`/`ref:`). Files
     that matter: those five paths + your roster + `.env`.
4. **ARMING FOR ANY LANGUAGE.** The app's only obligation: a `sssf.app.yaml`
   manifest at the app root. Fields:
   - `runtime: bun|node|uv|none` — CDN-bootstrapped by provision.sh, never
     apt; a runtime the image cannot provide is a named failure.
   - `install:` — list of shell commands run from the app root at setup.
   - `build:` — same, optional.
   - `serve:` — `command` / `port` (default 4501) / `health_path` (default
     `/`); optional — absent = observe skips the app lane (library/CLI app).
   - `checks:` — the deterministic quality gate. Map form `name: [argv...]`
     or list form `{name, area, operation, argv, timeout_seconds}`; absent =
     the SDLC runs without it.
   Give two example manifests: one bun (e.g. `runtime: bun`,
   `install: [bun install]`, `serve: {command: bun run server.ts, port: 4501}`,
   `checks: {test: [bun, test]}`) and one python/uv (`runtime: uv`,
   `install: [uv sync]`, `checks: {test: [uv, run, pytest]}` — no `serve:`).
5. **PREREQUISITES + ARMING CHECKLIST.** Host: `uv`, `bun`, `just`, ssh access
   to exe.dev (`ssh exe.dev whoami` works). `.env`: copy `.env.sample`; set the
   LLM provider keys your roster's models need (FILL names the missing ones);
   `SSSF_CONFIG` pointing at your roster (default
   `adws/adw_sssf_config/sssf.config.yaml`); `APP_REPO_GIT_TOKEN` only if the
   app repo is private. Then `just sbx manage doctor`.
6. **USE.** The loop:
   - `just sbx mount <run-id>` — create→fill→setup (health gate A–E)→observe;
     prints the follow-up commands.
   - `just sbx lifecycle execute <run-id> "add X"` — detached SDLC (default
     chain `sdlc`; 4th positional picks another, e.g.
     `just sbx lifecycle execute <run-id> "add X" "" simple-sdlc`).
   - Watch: `just obs sessions`, `just obs phases <adw_id>`,
     `just obs tail <adw_id>`, `just sbx run cmd <run-id> 'tail -f run.log'`,
     or the UI at `https://<vm>.exe.xyz:4600/`.
   - `just sbx manage harvest <run-id>` — pull the run's commits home as a
     verified bundle into `refs/sandbox/<run-id>`.
   - `just sbx lifecycle teardown <run-id>` — always explicit; harvests first,
     and a failed harvest aborts the destroy.

## Verification (builder must run)

1. Re-check every command against the justfiles:
   `just --list`, `just --list sbx`, `just --list sbx::lifecycle`,
   `just --list sbx::manage`, `just --list sbx::run`, `just --list adw`,
   `just --list obs` — confirm every command the README prints resolves.
2. `grep` the README for every path it names (`adws/adw_sssf_config/sssf.hello.config.yaml`,
   `sandbox_mount/guest/provision.sh`, `.claude/skills/sssf/apps/visualizer/`,
   etc.) and confirm each exists in the tree.
3. Confirm the execute-usage lines match `execute.just`'s signature
   (`RUN_ID PROMPT CONFIG="" ADW="sdlc"`).
4. `git status` — only `README.md` modified (plus this plan's spec file).

## Out of scope

Everything that is not `README.md`. No code, justfile, roster, or
provisioner changes — even where comments are stale (the hello-roster
TypeError caveat), that is a separate run's job.
