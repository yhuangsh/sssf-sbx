# sssf-sbx

The kernel that arms **any repo, in any language**, with SSSF agents and
exe.dev sandboxes for its own development. Clone or vendor it, point it at your
app, and your project runs the same plan → build → test → review → document
loop — each run on a disposable VM, with its commits bundled back to you.

Two layers live in one repo:

- **The agent layer** (`adws/`) — the SSSF chains: 12 `adw_*.py` workflows,
  the `adw_modules/` runtime (agents, runner, session, tracer, gates, quality,
  permissions), the prompt/harness engineering under `adw_data/`, and the
  rosters where you name models, tools, and per-agent write scope.
- **The sandbox layer** (`just/sandbox/`, `sandbox_mount/`) — the exe.dev
  lifecycle that mounts an app into its own VM: `create → fill → setup →
  observe`, plus `execute`, `harvest`, and an always-explicit `teardown`.
  `sandbox_mount/host/` holds the run record and roster-key checks;
  `sandbox_mount/guest/provision.sh` is the guest provisioner, streamed
  host-side at `setup`.

Philosophy: **deterministic Python owns sequencing and gates; agents own
judgement.** The justfiles and `adw_modules/` decide what runs, in what order,
and whether it passed; the models only write the code.

## Directory map

| path | role |
| --- | --- |
| `justfile` | Root entry point. Mounts `mod adw` (the chains), `mod sbx` (sandbox orchestration), `mod obs` (trace db). The `adw`/`sbx` split is by credential — the exe.dev account never leaves the host, so a sandbox cannot mount sandboxes. |
| `just/adws.just` | The in-sandbox chain recipes — `adw sdlc`, `simple-sdlc`, `plan-build-test-quality`, `prompt`, `scout`, … each runs `uv run adws/adw_*.py --config <roster>`. |
| `just/obs.just` | Read the trace db (`adws/adw_data/sssf.db`): `sessions`, `phases`, `tail`, `procs`, `kill`, `rosters`, and `ui` (boots the visualizer). |
| `just/sandbox/` | The sandbox layer. `mount.just` is the chain; `scaffold.just` is the interactive app-repo scaffolder; `lifecycle/` holds the six phases (`create`, `fill`, `setup`, `execute`, `observe`, `teardown`); `manage/` holds `doctor`, `list`, `harvest`; `run/` holds the `agent` and `cmd` lanes. |
| `sandbox_mount/host/` | Host-side helpers: `run_record.py` (the only cross-phase state), `scaffold.py` (interactive `just sbx scaffold`; `gh`-driven), `roster_keys.sh` (asserts every roster provider's key is set), `runs_table.py` (formats `manage list`). |
| `sandbox_mount/guest/provision.sh` | The guest provisioner, streamed over ssh at `setup`. Bootstraps bun + just, standalone Node/npm, pi at the registry `latest`; then installs the app per its manifest. **Never apt.** |
| `adws/` | The agent layer: 12 `adw_*.py` chains, the `adw_modules/` runtime, `adw_data/prompt_engineering/` + `adw_data/harness_engineering/`, and `adw_sssf_config/` rosters. |
| `.claude/skills/sssf/apps/visualizer/` | The trace UI (Vue + bun). `just obs ui` boots it; in a sandbox `observe` serves it on :4600. |
| `.env.sample` | Template for `.env` — LLM provider keys plus the optional app-repo token. |
| `LICENSE` | MIT. |

## Integration — two ways to attach an app

### (a) Toolbelt — recommended

Keep `sssf-sbx` as its own clone; your app stays an **external git repo**. A
roster's `app:` block (`repo:` / `ref:` / `path:` / `manifest:`) points at it.
`fill` clones that repo into `~/app/<path>` on the VM, the run branch
`sbx/<run-id>` and **every** ADW commit land there, and `harvest` bundles them
into a bare cache under `.sandbox/repos/` — the factory clone stays
byte-identical across apps.

The shipped template `adws/adw_sssf_config/sssf.hello.config.yaml` points at the
public `hello-server` example:

```yaml
app:
  repo: https://github.com/yhuangsh/hello-server.git
  ref: main
  path: target
  manifest: sssf.app.yaml
```

Copy that roster, edit the `app:` block, and run with `SSSF_CONFIG=<your
roster>`. **Files that matter: your roster copy + `.env`.** A run with
`SSSF_CONFIG` unset fails fast with the named error above — it never falls back
to the template.

### (b) Vendored

Copy `adws/`, `just/`, `sandbox_mount/`, `.env.sample`, and
`.claude/skills/sssf/apps/visualizer/` into your own repo, then set the default
roster's `app.path` to your app dir (leave out `repo:`/`ref:` — the payload
lives in this clone):

```yaml
app:
  path: apps/your-app
  manifest: sssf.app.yaml
```

**Files that matter: those five paths + your roster + `.env`.**

### Scaffolding a new app: `just sbx scaffold`

Don't hand-write the repo, the manifest, or the roster — generate them. Run
from the kernel checkout:

```sh
just sbx scaffold            # interactive; prompts for everything
just sbx scaffold owner/name # pre-fills the repo name
```

It asks (sane defaults, bare Enter accepts): repo name, **exists** or
**create-new** (and public/private if new), runtime (**bun** — the default —
`node`, `uv`, or `none` for a library), whether the app **serves** (command,
port, `health_path`), and whether to add the skeleton's **test check**. It
prints a summary and asks before doing anything destructive.

What it produces, so the next command is a plain `just sbx mount`:

- **create-new** — `gh repo create <owner>/<name> --<visibility> --push` with a
  runtime-matched skeleton (`bun`: `package.json` + `server.ts` +
  `server.test.ts`; `node`: zero-dependency `node:http` + `node --test`; `uv`:
  `pyproject.toml` + pytest; `none`: README-only), an `sssf.app.yaml` manifest,
  and a `.gitignore`.
- **existing** — `gh repo clone`, then **add only what is missing** (manifest,
  skeleton if the repo is empty-ish, `.gitignore`). Existing files are never
  overwritten: an existing `sssf.app.yaml` is kept unless you say otherwise.
- **private repos** — checks `APP_REPO_GIT_TOKEN` in the host `.env` and offers
  to add it from `gh auth token`; without it `fill` fails with
  `APP_REPO_PRIVATE_NO_TOKEN`.
- **the roster** — writes `sssf.<name>.config.yaml` **in the current directory**
  (the kernel clone root, next to `.env` and the justfile) from the shipped hello
  template (only the `app:` block changed) and leaves it **untracked** — the
  roster is your file. If that file already exists the scaffolder asks
  (overwrite / pick another name / abort) rather than clobbering. Committing the
  roster into the kernel repo for team sharing is your choice; a useful side
  effect is that generated rosters no longer touch the kernel's git history. Then
  it prints the next steps:

```sh
# [scaffold] done — <owner>/<name> (public) + roster sssf.<name>.config.yaml (untracked — your file, not committed)
#   1. point SSSF_CONFIG at it, in .env or inline:   SSSF_CONFIG=sssf.<name>.config.yaml
#                                                    (relative roster paths resolve from this repo root)
#   2. preflight:     just sbx manage doctor
#   3. mount:         just sbx mount <run-id>
```

**`gh`, installed and authenticated (`gh auth login`), is a hard dependency of
this one command** — it is the only `sbx` command that needs it, and it fails
with named guidance if `gh` is absent or not logged in.

## Arming for any language

Your app's only obligation is a `sssf.app.yaml` manifest at the app root. The
runtime is whatever `provision.sh` can supply; there is no apt fallback.

| field | meaning |
| --- | --- |
| `runtime:` | `bun` \| `node` \| `uv` \| `none`. CDN-bootstrapped (bun from bun.sh, Node from nodejs.org, uv from the image) — never apt. A runtime the image cannot provide is a named failure. `none`/absent skips the check. |
| `install:` | List of shell commands, run from the app root at `setup` **with the app's environment**: the `APP_*` secrets and the shipped LLM keys from `app/.env` are already in the environment (see [App credentials](#app-credentials-the-app_-namespace)). |
| `build:` | Same, optional — also runs with the app's environment (`APP_*` secrets + `app/.env` LLM keys; see [App credentials](#app-credentials-the-app_-namespace)). |
| `serve:` | Optional. `command`, `port` (default `4501`), `health_path` (default `/`). **Absent = `observe` skips the app lane** (library/CLI apps). |
| `checks:` | The deterministic quality gate. Map of `name: [argv...]`, or a list of `{name, area, operation, argv, timeout_seconds}`. **Absent = the SDLC runs without it.** |

Bun app:

```yaml
runtime: bun
install:
  - bun install
build:
  - bun run build
serve:
  command: bun --hot server.ts  # --hot: live reload — Bun re-imports the module graph without restarting the server
  port: 4501
  health_path: /
checks:
  test: [bun, test]
```

Python / uv app (no server — `observe` skips the app lane):

```yaml
runtime: uv
install:
  - uv sync
checks:
  test: [uv, run, pytest]
```

### App credentials: the `APP_*` namespace

Extra credentials your app's provisioning needs go in the host `.env` as `APP_*`
variables. They ship into the sandbox by the same stdin/0600 path as the LLM
keys, land in `app/.env`, and `provision.sh` sources that file before each
manifest command — so the manifest's `install:`/`build:` commands see them as
environment variables with no hand-sourcing. Host-only overrides (`SSSF_CONFIG`,
`PI_*`, `ENGINEER_NAME`) never cross.

```sh
# .env (host) — a marked example; use a reusable, ephemeral-tagged key
APP_TAILSCALE_AUTHKEY=tskey-...
```

```yaml
# sssf.app.yaml — install tailscale and join a tailnet during install
runtime: none
install:
  - command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
  - sudo tailscale up --auth-key="$APP_TAILSCALE_AUTHKEY" --ephemeral
```

Auth keys should be reusable and **ephemeral-tagged** so disposable VMs do not
accumulate in the tailnet. The first mount after adding a heavy install
downloads over a slow link; idempotent guards like `command -v tailscale` keep
re-mounts fast.

## Prerequisites + arming checklist

Host tools: `uv`, `bun`, `just`, and ssh access to exe.dev
(`ssh exe.dev whoami` must work). Then:

1. `cp .env.sample .env` and set the LLM provider keys your roster's models
   need — `fill` derives the required set from the roster's `model:
   provider/id` entries and fails, naming any that are missing.
2. Point `SSSF_CONFIG` at your roster — **required, there is no default**;
   every roster-consuming command below fails fast without it. The shipped
   `adws/adw_sssf_config/sssf.config.yaml` is a template only.
3. Add `APP_REPO_GIT_TOKEN` **only if** the app repo is private (public repos
   clone unauthenticated), plus any other `APP_*` secrets your manifest's
   `install:`/`build:` commands need (e.g. `APP_TAILSCALE_AUTHKEY`) — see
   [App credentials](#app-credentials-the-app_-namespace) above.
4. Preflight: `just sbx manage doctor`.

## Which commands need SSSF_CONFIG

`SSSF_CONFIG` names the roster (models, agent scopes, and the `app:` block) the
run uses. **It is required — there is no default roster.** When it is unset or
empty, every roster-consuming command fails fast on the host, before any VM is
created, with this exact message on stderr:

```
SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming.
```

The one exception class is the **shipped per-sandbox copy**: `fill` writes the
active roster to a fixed path inside the VM (`/home/exedev/sssf_config.yaml`),
and the in-sandbox phases read *that* file — `ssh` carries no environment, which
is why they take an explicit `CONFIG` argument rather than reading
`SSSF_CONFIG`. Those commands are listed as **no** below.

| command | needs `SSSF_CONFIG`? | why |
| --- | --- | --- |
| `just sbx mount` | yes | preflight parses the roster's `app:` block |
| `just sbx lifecycle create` | yes | derives the VM tag from `app.repo` |
| `just sbx lifecycle fill` | yes | ships THIS roster verbatim to `/home/exedev/sssf_config.yaml` |
| `just sbx lifecycle teardown` | yes | the `app:` block picks the artifact set |
| `just sbx manage doctor` | yes | roster provider-key preflight |
| `just sbx manage harvest` | yes | the `app:` block picks the repo the bundle comes from |
| `just adw …` (every chain: `sdlc`, `simple-sdlc`, `prompt`, …) | yes | its `--config` comes from `SSSF_CONFIG`; the chain itself refuses an empty one |
| `just obs …` (`sessions`, `phases`, `tail`, `procs`, `rosters`, `kill`, `ui`) | yes | same requirement, enforced by the shared guard |
| `uv run adws/adw_*.py …` (direct) | yes | `--config` is required |
| `just sbx lifecycle setup` | no | gates against the per-sandbox copy `fill` shipped at `/home/exedev/sssf_config.yaml` (ssh carries no environment; an optional `CONFIG` argument overrides) |
| `just sbx lifecycle execute` | no | forwards that same shipped path unless you pass `CONFIG` |
| `just sbx lifecycle observe` | no | reads the shipped copy remotely |
| `just sbx run agent` / `just sbx run cmd` | no | record-driven; the sandbox pi reads what `fill` shipped |
| `just sbx manage list` | no | reads run records only |

## Use

**Run everything below from the sssf-sbx clone root** — the directory
containing this README and the `justfile`. That is where `dotenv-load` finds
`.env`, where `SSSF_CONFIG` roster paths resolve, and what "repo root" means
in every phase. In **toolbelt** mode that root is your sssf-sbx checkout;
your app repo is a different repo and nothing here runs from it — `mount`
clones your app from GitHub into the VM at `~/app/target`, and a local clone
of your app is optional, only for host-side work. In **vendored** mode the
kernel directories live inside your app repo, so the two roots are the same
directory.

**Lane mental model** — users conflate steering with the factory; keep them
separate:

- **`just sbx run agent` / `just sbx run cmd`** — steering and inspection.
  `run agent` is ONE pi turn inside the box: no chains, no gates, no commits —
  its edits stay uncommitted working-tree changes.
- **`just sbx lifecycle execute`** — the factory: the full SDLC with gates,
  reviews, and commits to the target's run branch.
- **`just sbx manage harvest`** — bringing the run's commits home.
- **`just sbx mount` / `just sbx lifecycle teardown`** — the only times a
  sandbox is created or destroyed. A fresh mount is for a clean box, never
  needed just to test a change.

The app process starts once at `observe` and does not hot-reload unless the
app's own manifest opts in (see the serve example below).

The loop — mount, execute, watch, harvest, tear down:

```sh
# create -> fill -> setup (health gate A–E) -> observe; prints the follow-ups
just sbx mount my-run

# run the full SDLC detached inside the sandbox (default chain: sdlc)
just sbx lifecycle execute my-run "add X"

# the 4th positional picks another chain from `just adw` (3rd is the roster)
just sbx lifecycle execute my-run "add X" "" simple-sdlc

# watch it
just obs sessions
just obs phases <adw_id>
just obs tail <adw_id>
just sbx run cmd my-run 'tail -f run.log'   # or the UI at https://<vm>.exe.xyz:4600/

# pull the run's commits home as a verified bundle into refs/sandbox/<run-id>
just sbx manage harvest my-run

# tear down — ALWAYS an explicit decision; harvests first, and a failed
# harvest aborts the destroy
just sbx lifecycle teardown my-run
```

`mount` stops at `observe` on purpose; nothing ever chains `teardown`. The
sandbox holds no git credential, which is why `harvest` moves commits as a
bundle rather than a push. Other useful entries: `just sbx manage list` (all
runs + VM liveness), `just sbx run agent <run-id> "<prompt>"` (a resumable pi
session inside the box), and `just obs rosters` to see who is in which roster.

### Orchestrator

Boot a host-side orchestrator session that drives the phases above. The
**roster argument is mandatory** — the roster is the per-app input, so the
session is **focused** on the app it names:

```sh
# Claude Code
just sbx orch cc adws/adw_sssf_config/sssf.hello.config.yaml
# pi
just sbx orch pi adws/adw_sssf_config/sssf.hello.config.yaml
```

The boot validates the file (a missing one fails with `[orch] roster file
'<path>' not found` before anything launches), resolves it to an absolute path,
**exports `SSSF_CONFIG`** into the agent's environment — so every
roster-consuming command the session runs hits *that* roster, the explicit
argument overriding any `.env` value — and prints the roster's `app.repo` and
`app.path`. "Focus" means the whole session targets that app: orient on its
`app:` block and manifest first, then mount, develop via `just sbx lifecycle
execute`, steer with `just sbx run agent`, harvest, and (when the human decides)
teardown.

**Resume:**

- **pi** — re-run the same command. The recipe derives a deterministic session
  id from the roster basename (`sssf.hello.config.yaml` → `orch-hello`) and
  passes it via `--session-id`, which creates-or-continues, so you land back in
  the same orchestrator context.
- **cc** — `claude --dangerously-skip-permissions --continue` from this repo
  root continues the most recent orchestrator conversation.
