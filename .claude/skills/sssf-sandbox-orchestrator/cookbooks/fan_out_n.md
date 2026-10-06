# Fan Out to N

Best-of-N means **N separate sandboxes**. One run, one VM, one `app/.env`, one working tree, one git
state, one set of ports, one run branch.

## The rule, and why it is not negotiable

The problem this system exists to solve is that five agents on one machine fight over one working
directory, one dev-server port, and one git state. Running N agents inside a single sandbox
**reintroduces exactly that collision** — you have paid for a VM and bought nothing.

Isolation is not the only thing you would lose:

- **Spend attribution.** One box, one `app/.env`, one trace db is what makes "same prompt, N models,
  cost beside result" a table you can rank. N agents sharing one box produce one number nobody can
  decompose.
- **Blast radius.** A runaway arm can only chew its own box; there is no shared budget to exhaust.
- **The commit graph.** SSSF commits plan, code and docs separately. Two agents committing into one repo
  interleave their history and the `git bundle` at teardown is unreadable.
- **The gate.** A/B/C/D/E describe *one* sandbox's health. There is no per-agent version of it.

Getting one sandbox right is what makes N free. N is a loop over the same phases.

## The loop

Mint the run id yourself and pass it through the phases. **Do not use `just sbx mount` for fan-out:**
`mount` recovers the generated id by reading the newest record out of `run_record.py list`, which is
correct for one run and a race under concurrency.

`just sbx lifecycle create` only generates a new id when the argument does not already end in `-<6 hex>`,
so an id from `new-id` is used verbatim.

```bash
#!/usr/bin/env bash
set -euo pipefail
RR=sandbox_mount/host/run_record.py

PROMPT="add a word-count badge to the editor footer"
PIN=$(git rev-parse HEAD)          # one commit for every arm — this is the control variable
# Roster files live in the clone; a CONFIG arg is an ABSOLUTE path on the VM
# (ssh carries no cwd), so per-arm rosters point into the shipped factory clone.
ARMS=(
  "/home/exedev/app/adws/adw_sssf_config/sssf.config.yaml"
  "/home/exedev/app/adws/adw_sssf_config/sssf.hello.config.yaml"
)

for i in "${!ARMS[@]}"; do
  ID=$("$RR" new-id "bestof-$i")
  just sbx lifecycle create "$ID"               # tag derives from the ACTIVE host roster
  just sbx lifecycle fill   "$ID" "$PIN"         # pin every arm to the same sha or the comparison is noise
  just sbx lifecycle setup  "$ID" "${ARMS[$i]}"  # gate THIS arm's roster; on failure it STOPS and leaves the VM alive
  just sbx lifecycle observe "$ID"
  echo "$ID ${ARMS[$i]}" >> /tmp/fanout.map
done
```

Phases are ~12s cold per arm and mostly network wait, so backgrounding each arm's chain is fine. Two
things to know before you do: `just sbx lifecycle create` is the only phase that mints a run id, so id
generation must stay outside the parallel section (it already is), and a gate failure in one arm must
not abort the others — run each chain in its own subshell and collect exit codes.

**A failed arm stays up.** `just sbx lifecycle setup` never destroys. Read `debug_a_failed_gate.md`,
fix, re-run `just sbx lifecycle setup <id> <cfg>` for that arm only.

## Then execute

```bash
while read -r ID CFG; do
  just sbx lifecycle execute "$ID" "$PROMPT" "$CFG"   # detached; returns a pid, recorded
done < /tmp/fanout.map
```

`just sbx lifecycle execute` returns immediately. Watch any arm with
`just sbx run cmd <id> 'tail -f run.log'`, or open its observability UI
(`just sbx lifecycle observe <id>` printed both URLs).

## Where per-run variance lives

Three places, and nowhere else. Everything else stays inside the codebase — that is what keeps this
orchestrator a set of recipes instead of an agent system.

### 1. The prompt

`just sbx lifecycle execute <id> "<prompt>"`. The obvious axis, and the one worth varying least: if the
prompts differ, you are not comparing models, you are comparing prompts.

### 2. `SSSF_CONFIG` — the roster

A roster names an agent's coding agent, model, thinking level, tools and prompts — it is the single
richest per-run knob. `just sbx lifecycle execute` takes it as the **3rd positional** (`CONFIG`) and
`just sbx lifecycle setup` takes the same path, so **per-arm rosters are gated**, not just run:

```bash
just sbx lifecycle setup   "$ID" "$CFG"          # gate C/D/E check the roster you will run
just sbx lifecycle execute "$ID" "$PROMPT" "$CFG"  # the factory runs it
```

`CONFIG` is an **absolute path on the VM** (the check does not `cd` first). When you omit it, both
default to the per-sandbox copy FILL shipped at `/home/exedev/sssf_config.yaml` — which is the **active
host roster**, resolved from your own `SSSF_CONFIG` at fill time. To actually ship a different roster as
the box default, set `SSSF_CONFIG` to that arm's roster when you call `just sbx lifecycle fill`.

The module recipe is `uv run adws/adw_*.py --config {{config}} "$@"`, and argparse takes the **last**
`--config`, so a trailing `--config <path>` from `execute` wins over the module default. `SSSF_CONFIG`
(the env route) cannot work through ssh at all: `ssh vm "cmd"` reads no profile and carries no
environment.

### 3. The model

Edit a copy of the roster file: `defaults.model` for the whole roster, or `agents[].model` for one
agent. Ids are `provider/id` — pi splits on the **first** slash, so `openrouter/google/gemini-3.6-flash`
means provider `openrouter`, model `google/gemini-3.6-flash`.

A roster model just needs its **provider's env var in `.env`** (see `.env.sample`); pi's built-in
catalog carries each provider's baseUrl, api flavor and cost. There is no rate-table file to edit here.
A provider pi does not know is the one thing that needs new work — add it to
`sandbox_mount/host/roster_keys.sh` and gate E, or register it out of band.

### And the control: the commit pin

`just sbx lifecycle fill <id> <sha>` pins the arm. Hold it constant across arms or the comparison has
two variables. `commit_sha` is recorded from what actually got checked out, never from what was asked
for, and FILL gates that they match.

## Ranking the arms

`just sbx manage list` gives you state and VM liveness for every run. Beyond that,
`just sbx manage harvest <id>` each arm and diff the refs against each other with plain git — that is
the honest comparison anyway: the code is the artifact, not a score.

Where each column comes from:

| Column | Source |
|---|---|
| run id, vm, tag, closed | `.sandbox/runs/<id>.json` via `run_record.py list` |
| commit | run record `commit_sha` (the input), plus the run's own commits in the harvest bundle (the output) |
| model (per agent) | trace db `agent_sessions.model` |
| tokens, cost, status, request | trace db `sessions.total_tokens`, `total_cost`, `status`, `request` |

Today:

```bash
# every run, newest first — run_id, vm_name, tag, commit_sha, closed_at
sandbox_mount/host/run_record.py list

# per-arm result, read live off the VM
just sbx run cmd <id> "sqlite3 adws/adw_data/sssf.db 'select adw_id, status, total_tokens, round(total_cost,4) from sessions order by started_at desc limit 5;'"
just sbx run cmd <id> "sqlite3 adws/adw_data/sssf.db 'select agent, model, context_tokens from agent_sessions;'"
```

Per-arm cost is `sessions.total_cost` — pi's own accounting in the trace db, not a key readout. **Best-of-N
spend attribution = compare that column across the harvested runs.**

## The golden-VM path (N >= 3) — not yet exercised

A cold mount is ~12s (1.9s boot + 2.6s clone + toolchain + deps). A `cp` of a warm VM is **0.37s
server-side, ~1s wall**. At N=2 that is noise; at N>=3 it starts to matter.

**`sync` THEN `cp`. Always.**

```bash
ssh <golden>.exe.xyz 'sync'                  # MANDATORY
ssh exe.dev cp <golden> <run-id> --json
```

An unsynced `cp` produced **5,641 zero-byte files and reported no error**. The clone looked complete:
files existed, `just --list` exited 0, and thousands of them were empty. That is precisely why gate A
checks `git status --porcelain` rather than that files exist.

Any snapshot wrapper that does not `sync` is unsafe — call `sync` yourself before the `cp`, or skip the
wrapper.

What still runs after a `cp`:

- **FILL still runs.** A clone's code is stale by definition, and each arm needs its own credentials in
  `app/.env`. FILL handles both: it detects an existing `app/.git` and fetches instead of cloning, and
  it fast-forwards with `--ff-only` so it can never reset over commits an earlier run produced.
- **SETUP still runs.** provision.sh is idempotent (skip-if-present installs, `CREATE TABLE IF NOT
  EXISTS`), so run it unchanged and let the gate do its job. The gate matters *more* here, not less — the
  zero-byte failure mode is unique to this path.
- **CREATE is different.** `cp` creates the VM, so the `ssh exe.dev new` in `create.just` is not what you
  want. There is no golden-VM variant of `just sbx lifecycle create` today; wiring one is the work this
  path needs.

Costs: a golden VM bills continuously while it sits idle — exe.dev VMs are persistent and never expire.
And it drifts: the toolchain it carries is the toolchain of the day you built it.

**This whole path is unexercised.** The five phases were verified end to end on a live VM by cold mount.
The golden-VM route is designed, measured (0.37s, 5,641 files) and written down — but no run has been
mounted through it. Treat the first one as an experiment, not an optimization.

## Cleanup

N sandboxes means N live VMs, all billing until someone decides otherwise. Nothing expires and nothing
auto-destroys. Tear each arm down explicitly when you have its artifacts — harvest runs first, and a
failed harvest aborts the destroy (see `teardown_and_reap.md`).

There is **no `reap` recipe** in this kernel. The backstop for an arm whose teardown never ran is to
list and filter by hand:

```bash
just sbx manage list            # record state + VM liveness
ssh exe.dev ls                  # the control-plane truth
ssh exe.dev rm <vm>             # a VM whose run record is gone
```

The **tag** you mounted each arm with (fact: `create` derives it from `app.repo`, or you pass one) is
what bulk identification filters on — that is why a run mounted with the wrong tag is a fleet-hygiene
bug.
