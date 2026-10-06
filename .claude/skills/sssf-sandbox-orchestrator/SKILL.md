---
name: sssf-sandbox-orchestrator
description: Drive the sandbox mount system from the host — mount throwaway exe.dev VMs, run the Super Simple Software Factory inside them, watch from outside, harvest the commits, tear down. Use when the user says mount a sandbox, run the factory in a sandbox, spin up N sandboxes, best-of-N, check on a run, harvest a run's commits, or tear down. Keywords - sandbox, mount, exe.dev VM, run id, fan out, best-of-N, harvest, bundle, teardown.
argument-hint: "[mount|execute|agent|observe|harvest|teardown] [run-id or prompt]"
---

# SSSF Sandbox Orchestrator

Drives the **out-of-sandbox** half of this repo: the `sbx` namespace under `just/sandbox/` that takes
a blank exe.dev VM to a health-checked, running factory in ~10s, runs work inside it, exposes it to a
browser, and — only when a human says so — tears it down.

## The one governing principle: THIN SKILL, FAT RECIPES

**Every action you take should be a `just` command a human could type.** The recipes hold the
knowledge; this skill holds the judgment about which one to run and how to read the result.

- Dropping to `ssh <vm>.exe.xyz '...'` or `curl` to **inspect** is fine and expected — that is what
  `just sbx run cmd <id> '<cmd>'` exists for, and reading a log or a table needs no ceremony.
- Re-implementing what a recipe already does is not. Never hand-roll an `ssh exe.dev new`, a
  `share port`, a roster ship, a delta-tar pull, or a detached `nohup` launch. Those encode measured
  facts (create order, the arming preflight, the harvest-first teardown, the three detachment
  pieces) and a hand-rolled version drops one of them silently.
- If a recipe is wrong, **fix the recipe** and say so. Do not route around it.

## SSSF_CONFIG is required — set it before any roster-consuming command

`SSSF_CONFIG` names the roster (models, agent scopes, and the `app:` block) the run uses. **There is
no default roster, and no silent fallback to a template.** Export it inline or put it in `.env` (the
recipes `dotenv-load`) **before** you run anything that consumes a roster. Unset, the shared guard
`sandbox_mount/host/require_sssf_config.sh` prints this and exits 1:

```
SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming.
```

Commands that **require** `SSSF_CONFIG` on the host: `just sbx mount`, `just sbx lifecycle create`,
`just sbx lifecycle fill`, `just sbx lifecycle teardown`, `just sbx manage doctor`, `just sbx manage
harvest`, every `just adw …` chain, and every `just obs …` query.

Commands that **do not**: `just sbx lifecycle setup`, `just sbx lifecycle execute`, `just sbx
lifecycle observe`, `just sbx run agent`, `just sbx run cmd`, and `just sbx manage list`. The
in-sandbox phases read the per-sandbox copy `fill` shipped to `/home/exedev/sssf_config.yaml` (`ssh`
carries no environment), with an optional `CONFIG` argument to override. `README.md → "Which commands
need SSSF_CONFIG"` has the full table; the list above is its summary.

## Dependencies

This skill **references this repo's own sources** rather than duplicating them. They move without
asking us, and a copy pasted here would be a second source of truth that goes wrong quietly:

- `README.md` — the lane mental model, the arming checklist, and the `SSSF_CONFIG` table.
- the recipes under `just/sandbox/` — their header comments are the deep specs for each phase.
- `sandbox_mount/host/run_record.py` — the run-record `FIELDS` (the closed schema).
- `sandbox_mount/host/roster_keys.sh` — the provider → env-var map (gate E carries a second copy).

**Preflight is one command.** Run it before the first phase; any failure means report and stop, never
work around a missing prerequisite by hand.

```bash
just sbx manage doctor
```

It resolves the roster through the same guard (unset → the named error above *is* the report), then
prints exactly five checks, in order:

```
  ok    ssh exe.dev reachable
  ok    run_record helper runs
  ok    provisioner present
  ok    roster provider keys set
  ok    adw layer resolves
  sbx doctor: OK
```

In **vendored** mode (the roster has no `app.repo`) it prints one more, arming-visibility line that
**never affects the exit code**:

```
  ok    app.path <path> present (armed)
```

or, when the directory is missing, the UNARMED warning:

```
  WARN  app.path <path> missing in this repo — kernel is UNARMED: write <path>/sssf.app.yaml, or set app.repo: in your roster (README -> Arming)
```

Green ends with `  sbx doctor: OK`; any `FAIL` ends with `  sbx doctor: FAILED` and exit 1.

> **Listing a namespace is `just --list sbx`, not `just sbx --list`.** The latter reads `--list` as a
> recipe name and errors with ``Justfile does not contain recipe `sbx --list` ``. A bare `just sbx`
> also works — it runs the namespace's `default`, which lists.

## Two layers, one credential boundary

| | Out-sandbox (you) | In-sandbox (the VM) |
|---|---|---|
| Lives in | `just/sandbox/`, `sandbox_mount/host/` | `just/adws.just` (`mod adw`), `adws/`, `sandbox_mount/guest/` |
| Entry point | `just sbx mount`, `just sbx lifecycle execute`, `just sbx lifecycle teardown` | `just adw sdlc "..."` (see `just/adws.just`) |
| Credential | the exe.dev account (never leaves the host) | LLM provider keys shipped by FILL into `app/.env` (0600, allowlisted) + optional `APP_REPO_GIT_TOKEN` for private app repos |

The whole repo ships to the sandbox, this skill included. **What a sandbox cannot do is USE the
out-sandbox half** — `just sbx mount` there fails on a missing exe.dev account. That credential never
leaves the host, and that, not file absence, is what stops a sandbox from mounting sandboxes. Keep the
account on the host.

## The lane mental model, and where you run from

**Run everything from the sssf-sbx clone root** — the directory containing the README and the
`justfile`. That is where `dotenv-load` finds `.env`, where `SSSF_CONFIG` roster paths resolve, and
what "repo root" means in every phase. In **toolbelt** mode that root is your sssf-sbx checkout and
your app is a different repo, cloned by `fill` to `~/app/<path>` in the VM; in **vendored** mode the
kernel directories live inside your app repo, so the two roots coincide.

Keep the lanes separate — users conflate steering with the factory:

- **`just sbx run agent` / `just sbx run cmd`** — steering and inspection. `run agent` is ONE pi turn
  inside the box: no chains, no gates, no commits.
- **`just sbx lifecycle execute`** — the factory: the full SDLC with gates, reviews, and commits to
  the run branch `sbx/<run-id>`.
- **`just sbx manage harvest`** — bringing the run's commits home.
- **`just sbx mount` / `just sbx lifecycle teardown`** — the only times a sandbox is created or
  destroyed. A fresh mount is for a clean box, never needed just to test a change.

## The drive surface

Four groups under `sbx`, plus `mount` at the top because it is the entry point, not a phase:

```
just sbx
├── mount              the chain: create → fill → setup → observe
├── lifecycle          the six phases, for when you need one on its own
├── manage             preflight, readback, fleet ops — nothing here is a phase
├── run                put work in / look inside: `run cmd`, `run agent`
└── orch               boot a host-side orchestrator: `orch cc`, `orch pi`
```

`just sbx`, `just sbx lifecycle`, `just sbx manage`, `just sbx run` and `just sbx orch` each list
their own contents when run bare.

| Command | What it does |
|---|---|
| `just sbx mount RUN_ID [TAG]` | arming preflight → create → fill → setup → observe. **Never teardown.** Prints the resolved run id and both URLs. |
| `just sbx lifecycle create RUN_ID [TAG]` | boot one VM, in record → VM → tag-confirm → ssh-wait order; mints `session_id`. Derives the tag from `app.repo` when no explicit tag is given. |
| `just sbx lifecycle fill RUN_ID [SHA]` | clone the factory into the VM (public fork, optional SHA pin), ship the roster verbatim to `/home/exedev/sssf_config.yaml`, write `app/.env` from the allowlist, and clone the target app in target mode |
| `just sbx lifecycle setup RUN_ID [CONFIG]` | `provision.sh` + the five-assertion gate |
| `just sbx lifecycle execute RUN_ID PROMPT [CONFIG] [ADW] [*EXTRA]` | a `just adw` chain (default `sdlc`) detached inside the box; returns a pid, records it |
| `just sbx run cmd RUN_ID '<cmd>'` | generic escape hatch, synchronous, runs in `app/`. Your inspection tool. |
| `just sbx run agent RUN_ID "PROMPT"` | one **pi** turn inside the box, resumable `--session-id` — hand off, then keep talking |
| `just sbx lifecycle observe RUN_ID` | start the app (roster `app.path`, manifest `serve:` port) and the trace UI, expose the app port, print URLs. A manifest with no `serve:` skips the app lane. |
| `just sbx manage list` | every run record: state and VM liveness |
| `just sbx manage harvest RUN_ID` | pull the run's commits home as a git bundle, fetched into `refs/sandbox/<run-id>`. Non-destructive, idempotent, run it any time. |
| `just sbx lifecycle teardown RUN_ID [--no-harvest]` | artifacts (a gzipped delta-tar) → **harvest** → destroy → close. **The only destructive recipe**; a harvest failure aborts before the destroy. |

The run id is the handle for every phase. `create` appends `-<date>-<6 hex>` if you did not, and
prints what it settled on — use that string, not the one you typed.

**The five gate assertions** (`setup`): **A** git integrity (the factory tree clean — with the
configured `app.path` filtered out — HEAD matching `commit_sha`, plus `factory_sha` in target mode)
· **B** pi is current (== registry latest) and `pi --list-models` non-empty — *it exits 0 while
empty* · **C** every roster model answers a ping **through pi** · **D** a live pi call reports
**non-zero** cost, which proves pi's rate table loaded · **E** every roster provider's env key is
set. C, D and E run as one remote script whose exit code names the failing one (2 = C, 3 = D, 4 = E).
A failure **reports, stops, and leaves the VM alive**.

## Cookbooks (lazy-load the one the request calls for)

| Activity | When to read | File |
|---|---|---|
| Understand the recipes before running any | first time, or when a recipe surprises you | [cookbooks/just_command_model.md](cookbooks/just_command_model.md) |
| Stand up one sandbox end to end | "mount a sandbox", "run this in a sandbox" | [cookbooks/mount_one.md](cookbooks/mount_one.md) |
| Put work into a mounted box | "build X in there", "ask the agent", picking `run cmd` vs `lifecycle execute` vs `run agent` | [cookbooks/execute_work.md](cookbooks/execute_work.md) |
| Watch a run and report it back | "check on the run", "is it done", "show me the URLs" | [cookbooks/observe_and_report.md](cookbooks/observe_and_report.md) |
| Give the user access to a running box | "get me into the sandbox", a shell in there, talk to the in-box agent | [cookbooks/access_a_running_sandbox.md](cookbooks/access_a_running_sandbox.md) |
| A gate assertion failed | `setup` exited non-zero, or the box looks wrong | [cookbooks/debug_a_failed_gate.md](cookbooks/debug_a_failed_gate.md) |
| Spin up N and pick a winner | "best-of-N", "three variants", "diff the runs" | [cookbooks/fan_out_n.md](cookbooks/fan_out_n.md) |
| Shut a run down, do fleet cleanup | the human decided to tear down; orphaned VMs | [cookbooks/teardown_and_reap.md](cookbooks/teardown_and_reap.md) |

## References (deep specs, read on demand)

| Reference | Covers |
|---|---|
| [references/kickoff_paths.md](references/kickoff_paths.md) | the two ways work enters a box: direct (`lifecycle execute`, a command) vs agent-mediated (`run agent`, a delegation) |
| `README.md` | the lane mental model, the arming checklist, and the `SSSF_CONFIG` table (which commands need it) |
| the phase files' header comments under `just/sandbox/lifecycle/` | what each phase does, in order, and why the order is that order |
| `sandbox_mount/host/run_record.py` (`FIELDS`) | the closed run-record schema — who writes each field, who reads it |
| `sandbox_mount/host/roster_keys.sh` | the provider → env-var map (gate E carries a second copy that must stay in sync) |

## Hard rules

1. **Never decide teardown.** Report what the run produced, what it cost, and recommend — the human
   decides. `mount` stops at `observe` on purpose and nothing chains into `teardown`. A VM left
   running is a bill; a VM destroyed early is the evidence and the artifacts, gone. **`harvest` is
   the exception you may run freely** — it only reads the box and only writes `refs/sandbox/`, so run
   it as soon as a run commits rather than letting the commits wait on a teardown decision.
2. **Never run ADWs on the host.** `just adw sdlc "..."` here runs the factory on the engineer's
   laptop — the exact collision this system exists to remove. Work goes in through
   `just sbx lifecycle execute` / `just sbx run agent`, always.
3. **A gate failure means STOP and diagnose, never destroy.** The VM is left alive deliberately.
   Read the failing assertion, `just sbx run cmd <id> '...'` your way to the cause, fix it, re-run
   `just sbx lifecycle setup`. Re-running setup is safe.
4. **Never print or copy secrets.** `app/.env` is 0600 and holds the allowlisted provider keys and
   the optional `APP_REPO_GIT_TOKEN`; they never cross the wire in plaintext. FILL ships them over
   ssh stdin and prints proof lines that name the keys, never their values.
5. **Only `teardown` destroys, and VM tags name the app.** Bulk identification and cleanup filter on
   the tag, so a run mounted with the wrong tag is a fleet-hygiene bug — the tag derives from
   `app.repo` (or an explicit mount arg) and is recorded in the run record.
6. **Report the run id every time.** It is the only handle the next phase, the next session, and
   `teardown` have.
