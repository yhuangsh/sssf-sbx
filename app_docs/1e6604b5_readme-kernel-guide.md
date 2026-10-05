# README rewritten as the sssf-sbx kernel guide

The 3-line placeholder `README.md` ("Kernel README — being authored. See the
arming guide (coming with the next commit).") has been replaced with a
~165-line minimalist arming guide. The change lives in a single tracked file.

## What changed and why it matters

`README.md` is now the entry point a developer reads after `git clone
sssf-sbx`. It answers, in order, the six questions a kernel reader actually
asks: what is this, where do the pieces live, how do I attach my app, what
does my app have to provide, how do I arm the host, and what is the daily
loop. No badges, no roadmap, no marketing — the spec was explicit on that.

The rewrite is the kernel's first real README; the previous text was a
placeholder from the kernel's pre-release state. Until now, a new operator
had to read the justfiles, the rosters, and `provision.sh` to recover what
`sssf-sbx` actually does.

## Files that carry the change

- `README.md` — full rewrite, +164 −1. Sections: WHAT THIS IS (two layers
  + philosophy), DIRECTORY MAP (every top-level entry), INTEGRATION
  (toolbelt vs. vendored), ARMING FOR ANY LANGUAGE (the `sssf.app.yaml`
  manifest), PREREQUISITES + ARMING CHECKLIST, USE (the mount → execute →
  watch → harvest → teardown loop).
- `specs/1e6604b5_readme-kernel-guide.md` — the plan that produced the
  README. Captures the verified facts pulled from the justfiles, rosters,
  `provision.sh`, and `quality.py`, plus four corrections to the original
  task prompt (e.g. `execute` signature is `RUN_ID PROMPT CONFIG="" ADW="sdlc"`,
  not the `<id> <chain> "<prompt>"` form the prompt suggested).

## How to use it

A reader follows the README top-to-bottom:

1. Reads the WHAT THIS IS block to learn the agent/sandbox split and the
   "deterministic Python owns sequencing and gates; agents own judgement"
   rule.
2. Skims DIRECTORY MAP to locate each top-level dir/file's role
   (`justfile` + `mod adw`/`sbx`/`obs`, `just/adws.just`, `just/obs.just`,
   `just/sandbox/{mount,lifecycle,manage,run}/`, `sandbox_mount/host/`
   and `sandbox_mount/guest/provision.sh`, `adws/`,
   `.claude/skills/sssf/apps/visualizer/`, `.env.sample`, `LICENSE`).
3. Picks one of the two INTEGRATION modes:
   - **Toolbelt (recommended)** — keep `sssf-sbx` as its own clone;
     point the roster's `app:` block (`repo:`/`ref:`/`path:`/`manifest:`)
     at the external app repo. The shipped
     `adws/adw_sssf_config/sssf.hello.config.yaml` is the template, and
     it points at the public `hello-server` example. Only the roster copy
     and `.env` are app-specific.
   - **Vendored** — copy `adws/`, `just/`, `sandbox_mount/`, `.env.sample`,
     and `.claude/skills/sssf/apps/visualizer/` into the app's own repo;
     set the default roster's `app.path`. Five paths + roster + `.env`.
4. Drops a `sssf.app.yaml` manifest at the app root. README documents the
   fields (`runtime`, `install`, `build`, `serve`, `checks`) and gives two
   worked examples — a bun server app and a python/uv library (no
   `serve:` — observe skips the app lane).
5. Runs the PREREQUISITES + ARMING CHECKLIST: `cp .env.sample .env`,
   fills the LLM keys the roster needs, points `SSSF_CONFIG` at the
   roster, sets `APP_REPO_GIT_TOKEN` only for private app repos, then
   `just sbx manage doctor`.
6. Drives the USE loop:
   - `just sbx mount <run-id>` — chains create → fill → setup (health
     gates A–E) → observe; teardown is never chained.
   - `just sbx lifecycle execute <run-id> "<prompt>"` — detached SDLC
     (default chain `sdlc`). The 4th positional picks another chain,
     e.g. `just sbx lifecycle execute <run-id> "add X" "" simple-sdlc`.
   - Watch via `just obs sessions`, `just obs phases <adw_id>`,
     `just obs tail <adw_id>`, `just sbx run cmd <run-id> 'tail -f run.log'`,
     or the visualizer at `https://<vm>.exe.xyz:4600/`.
   - `just sbx manage harvest <run-id>` — bundles the run branch
     `sbx/<id>` home into `refs/sandbox/<run-id>` (the sandbox holds no
     git credential, so it's a bundle, not a push).
   - `just sbx lifecycle teardown <run-id>` — always explicit; harvests
     first, and a failed harvest aborts the destroy.

## How to verify it

- `git log -- README.md` — the only commit touching the README in this
  run should be the rewrite.
- `wc -l README.md` — expect ~165 lines, not the prior 3.
- `grep -c '^## ' README.md` — expect six `##` section headers (WHAT
  THIS IS, Directory map, Integration, Arming for any language,
  Prerequisites + arming checklist, Use).
- Every command in the USE block resolves under `just`:
  `just --justfile justfile --evaluate` and the per-module lists
  (`just sbx::lifecycle`, `just sbx::manage`, `just sbx::run`,
  `just obs`) should show `mount`, `execute`, `teardown`, `doctor`,
  `harvest`, `cmd`, `agent`, `sessions`, `phases`, `tail`, `rosters`.
- Every file/path the README names exists in the tree:
  `justfile`, `just/adws.just`, `just/obs.just`,
  `just/sandbox/{mount.just,mod.just,lifecycle,manage,run}/`,
  `sandbox_mount/host/{run_record.py,roster_keys.sh,runs_table.py}`,
  `sandbox_mount/guest/provision.sh`,
  `adws/adw_sssf_config/{sssf.config.yaml,sssf.hello.config.yaml}`,
  `.claude/skills/sssf/apps/visualizer/`, `.env.sample`.
