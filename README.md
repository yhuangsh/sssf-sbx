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
| `just/sandbox/` | The sandbox layer. `mount.just` is the chain; `lifecycle/` holds the six phases (`create`, `fill`, `setup`, `execute`, `observe`, `teardown`); `manage/` holds `doctor`, `list`, `harvest`; `run/` holds the `agent` and `cmd` lanes. |
| `sandbox_mount/host/` | Host-side helpers: `run_record.py` (the only cross-phase state), `roster_keys.sh` (asserts every roster provider's key is set), `runs_table.py` (formats `manage list`). |
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
roster>`. **Files that matter: your roster copy + `.env`.**

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

## Arming for any language

Your app's only obligation is a `sssf.app.yaml` manifest at the app root. The
runtime is whatever `provision.sh` can supply; there is no apt fallback.

| field | meaning |
| --- | --- |
| `runtime:` | `bun` \| `node` \| `uv` \| `none`. CDN-bootstrapped (bun from bun.sh, Node from nodejs.org, uv from the image) — never apt. A runtime the image cannot provide is a named failure. `none`/absent skips the check. |
| `install:` | List of shell commands, run from the app root at `setup`. |
| `build:` | Same, optional. |
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
  command: bun run server.ts
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

## Prerequisites + arming checklist

Host tools: `uv`, `bun`, `just`, and ssh access to exe.dev
(`ssh exe.dev whoami` must work). Then:

1. `cp .env.sample .env` and set the LLM provider keys your roster's models
   need — `fill` derives the required set from the roster's `model:
   provider/id` entries and fails, naming any that are missing.
2. Point `SSSF_CONFIG` at your roster (default:
   `adws/adw_sssf_config/sssf.config.yaml`).
3. Set `APP_REPO_GIT_TOKEN` **only if** the app repo is private (public repos
   clone unauthenticated).
4. Preflight: `just sbx manage doctor`.

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
