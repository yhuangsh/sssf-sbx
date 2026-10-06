# Mount one sandbox

One command takes a blank exe.dev VM to a health-checked, running factory and stops:

```bash
just sbx mount <task-or-run-id> [TAG]
```

`mount` runs an **arming preflight → create → fill → setup → observe**. It never tears down. Teardown
is always a separate, explicit decision, and nothing on the success path destroys anything.

The four phases are also individually callable, and that is the debugging path: if `mount` stops,
re-run the phase that stopped rather than starting over. Every phase except `create` is idempotent.

## What you type

```bash
just sbx mount my-run              # tag derived from the roster's app.repo
just sbx mount my-run hello-server # explicit VM tag
```

The argument is a **task name**, not the final run id. `create` appends a date and six hex characters
(`my-run` → `my-run-20260804-e08747`) unless you pass something that already ends in `-<6 hex>`. The
suffix is not optional: the run id becomes the VM name and the VM name becomes a public hostname, so a
collision is two runs fighting over one URL.

The optional second argument is the **VM tag**. Leave it empty and `create` derives it from the
roster's `app.repo` basename (lowercased, sanitized, ≤32 chars); vendored mode (no `app.repo`) uses
`sssf`. An explicit tag always wins. The tag is recorded in the run record and confirmed on the VM —
a missing tag is fatal, because the tag is what bulk cleanup filters on.

Everything after `create` takes the **full run id**. `mount` echoes it, and prints it again at the end.

## Arming preflight — the failure that costs seconds, not a VM

`mount` resolves `SSSF_CONFIG` through the required-roster guard and parses the roster's `app:` block
**before any VM exists**. In vendored mode a missing `app.path` directory fails immediately on the
host:

```
[mount] app.path '<path>' does not exist in this repo — write <path>/sssf.app.yaml, or set app.repo: in your roster to mount an external app (README -> Arming)
```

That is the whole point: the same silence used to surface only at provision step 5 of 9, inside the
VM. Target mode (`app.repo` set) has nothing local to pre-check — the external repo is `fill`'s
problem.

## Timing

| Step | Measured (ancestor, for reference) |
|---|---|
| `ssh exe.dev new` → ssh answering | 1.9s |
| public `git clone` of the factory | 2.61s |
| bun + just from their CDNs | ~1s combined |
| cold `uv` PEP-723 resolve, warmed once | 3s |

That is ~10s of mechanical work. The health gate then spends **real model round trips** on top — one
ping per roster model, a pi version check, and one live pi call — so wall clock is longer than the sum
above and varies with the roster. Never `apt` anything into this path: measured ~148 kB/s and ~35s per
package from the dal region.

## Phase by phase

### 1. create — host only, control plane, no code on the box

Order is the design: **record → VM → tag-confirm → ssh-wait → session_id.**

- record first, so a crash anywhere after it leaves teardown a handle to work from;
- then boot the VM (`ssh exe.dev new --name <run-id> --tag <tag> --json`);
- then re-read the tag and fail if it did not land;
- then wait for ssh.

```
run id:  my-run-20260804-e08747
record:  .sandbox/runs/my-run-20260804-e08747.json
tag:     hello-server
vm:      creating my-run-20260804-e08747 (tag hello-server) ...
tag:     hello-server confirmed on my-run-20260804-e08747 (tags: hello-server)
vm:      my-run-20260804-e08747  ->  https://my-run-20260804-e08747.exe.xyz  (tag hello-server)
ssh:     waiting for my-run-20260804-e08747.exe.xyz (up to 60s) ...
ssh:     up after 4s
session: 8941a9f0-ac02-4678-be96-d578ac224c3b

created  my-run-20260804-e08747  (no code on the box yet)
next     just sbx lifecycle fill my-run-20260804-e08747
```

**Not idempotent.** The record is created with `O_EXCL`, so a second `just sbx lifecycle create` on the
same full run id fails rather than clobbering a live record.

### 2. fill — factory clone, pinned sha, roster + credentials

```bash
just sbx lifecycle fill <run-id> [SHA]
```

Plain `git clone` of the **public** kernel fork
(`https://github.com/yhuangsh/sssf-sbx.git`) — no auth, no GitHub integration, and `.git` comes with it
because SSSF commits its own plan, code and docs. Optional `SHA` (a sha, tag or branch) pins the run;
the pin is resolved **inside the clone**, so a short sha or a branch name works.

Then FILL ships, in order:

- **`app/.env`** from an allowlist of host `.env` vars — the LLM provider keys pi's built-in providers
  read, plus the optional `APP_REPO_GIT_TOKEN`. Host-only overrides (`SSSF_CONFIG`, `PI_*`,
  `ENGINEER_NAME`) are deliberately excluded. It goes over ssh stdin, mode 0600, and is never echoed —
  FILL prints a names-only proof line.
- **the roster verbatim** to `/home/exedev/sssf_config.yaml` (0644), plus a derived
  `~/.pi/agent/settings.json` so a bare `pi -p` lands on the roster's default provider/model/thinking.
- **the target app clone**: with `app.repo` set (target mode), FILL clones that repo to `~/app/<path>`
  at `app.ref` and puts the run branch `sbx/<run-id>` on it. A private repo authenticates through
  `APP_REPO_GIT_TOKEN` using an ephemeral `GIT_ASKPASS`; the token never lands in the stored origin URL
  (`APP_REPO_TOKEN_LEAK` guard) and failures are named `APP_REPO_PRIVATE_NO_TOKEN` /
  `APP_REPO_CLONE_FAILED`. Public repos clone unauthenticated.

With no `app.repo` (vendored mode) the payload stays in the factory clone and the run branch lives
there. The factory HEAD is recorded as `factory_sha`; the sha the run actually commits on becomes
`commit_sha`.

**Gate:** the checked-out HEAD equals the intended sha **before** the record is written — a failed fill
must leave `commit_sha` (the harvest baseline) untouched. Failure leaves the VM up.

**Idempotent**, including on a golden-VM `cp` where `app/` arrives stale: an existing `app/.git` is
fetched and fast-forwarded, never reset, because a sandbox that already ran an ADW carries commits
that *are* the run's output.

### 3. setup — provision inside, then the five-assertion gate

```bash
just sbx lifecycle setup <run-id> [CONFIG]
```

Streams the host working tree's `sandbox_mount/guest/provision.sh` over ssh stdin (the host copy is
authoritative — the gate is host-side, so provisioner and gate must be the same version), waits for
`/tmp/PROVISION_READY`, then gates.

`CONFIG` picks which roster the gate checks and defaults to the per-sandbox copy FILL shipped at
`/home/exedev/sssf_config.yaml`; a missing file fails the gate rather than silently falling back. Pass
the same path you pass to `just sbx lifecycle execute`.

provision does, in order: bun → just → standalone Node/npm → pi at registry `latest` → initialize the
trace db → install the app per its `sssf.app.yaml` manifest → touch the sentinel. **Never apt.**

The five assertions:

| | Asserts | Why it exists |
|---|---|---|
| **A** | the **factory** tree is clean (the configured `app.path` untracked-directory line filtered out) and HEAD matches the recorded sha — `factory_sha` in target mode, `commit_sha` for the target clone; vendored mode checks `commit_sha` against the factory HEAD | an unsynced golden clone produced 5,641 zero-byte files and reported success; truncation shows up as ` M path`. Filtering `?? <path>/` is expected content: custom app paths need **no `.gitignore` edit** |
| **B** | `pi --version` equals the registry latest **and** `pi --list-models` is non-empty and not "No models available", with `app/.env` sourced | `pi --list-models` **exits 0 while empty**; a stale image-baked pi would pass every other check while the mount's done-condition is false |
| **C** | every roster `model: provider/id` answers a ping **through pi** | catches credential, baseUrl, api-flavor or provider-entry drift before an agent burns a phase on it |
| **D** | a live pi call reports **non-zero cost** | pi's built-in rate table is what makes `agent_pi.py`'s `usage.cost.total` meaningful; without it every run logs `$0.0000` while really spending |
| **E** | every roster provider's env key is set in the sourced `app/.env` | the provider → env-var map is pi's `getApiKeyEnvVars`; an unknown provider means the map needs the new provider |

C, D and E run as **one** script inside the sandbox, so it touches only the keys FILL shipped into
`app/.env`. The remote exit code names the failure: **2 = C, 3 = D, 4 = E**.

```
[gate] A PASS  git integrity (target payload)
[gate] B PASS  pi current and built-in providers loaded from app/.env
[gate] C PASS  every roster model answered through pi
[gate] D PASS  non-zero cost on a live call
[gate] E PASS  every roster provider has its env key

[setup] GATE PASSED — <run-id> is healthy on <vm>.exe.xyz
[setup] next: just sbx lifecycle observe <run-id>
```

**A gate failure reports and STOPS, and leaves the VM alive.** That is deliberate: the evidence is on
the box. The failure message hands you the starting commands:

```
ssh <vm>.exe.xyz
ssh <vm>.exe.xyz 'cd app && git status --porcelain'
ssh <vm>.exe.xyz 'cd app && set -a && . ./.env && set +a && pi --list-models'
```

Only `just sbx lifecycle teardown` destroys.

**Idempotent.** The sentinel is deleted before provisioning, so a re-run cannot find the previous
run's sentinel and declare victory early.

### 4. observe — start the app and the trace UI, expose the app port, print URLs

See [observe_and_report.md](observe_and_report.md). In one line: the app (the roster's `app.path`, on
its manifest's `serve:` port, default 4501) is exposed anonymously (200); the trace UI on 4600 is
owner-gated (307 anonymously, which is correct); both ports are recorded into the run record. A
manifest with **no `serve:` block** is a library/CLI app — the app lane is skipped, not failed.

## What each phase writes to the run record

The record (`.sandbox/runs/<run-id>.json`, gitignored) is the **only** state shared across phases —
each phase is a separate process. Its schema is closed: `run_record.py` rejects unknown keys, so a typo
in a `set` fails loudly instead of silently losing data. The fields are
`run_id`, `vm_name`, `tag`, `https_url`, `session_id`, `commit_sha`, `factory_sha`, `ports`, `pid`,
`created_at`, `closed_at`.

| Phase | Writes |
|---|---|
| create | `run_id`, `created_at`, `vm_name`, `https_url`, `tag`, `session_id` |
| fill | `factory_sha` + `commit_sha` (the sha actually checked out, never the one asked for) — plus `app/.env` and the roster on the VM |
| setup | **nothing** — it only reads `vm_name` and the shas |
| execute | `pid` |
| observe | `ports` (`{"app":4501,"obs":4600}`, or obs-only when the app lane is skipped) |
| teardown | `closed_at` — and the artifact delta-tar + the harvest bundle beside the record |

Read it directly whenever you need a field:

```bash
sandbox_mount/host/run_record.py get <run-id>            # whole record as JSON
sandbox_mount/host/run_record.py get <run-id> vm_name    # bare value, for shell capture
sandbox_mount/host/run_record.py list                    # every record, newest first
```

> `just sbx manage list` is the run table. `run_record.py list` is the same data unformatted, for when
> you want to pipe it.

## After mount

```
mounted: my-run-20260804-e08747
  execute: just sbx lifecycle execute my-run-20260804-e08747 "<prompt>"
  agent:   just sbx run agent my-run-20260804-e08747 "<prompt>"
  harvest: just sbx manage harvest my-run-20260804-e08747
  destroy: just sbx lifecycle teardown my-run-20260804-e08747
```

## Two things that bite

- **Do not run two `just sbx mount`s concurrently from this repo.** `mount` learns the generated run id
  by reading the **newest** record (`run_record.py list | … [0]["run_id"]`), so two overlapping mounts
  will hand the second run's id to the first run's `fill`. For parallel fan-out, call `create`
  yourself, capture the printed run id, and drive the phases per id.
- **`mount` stops at observe on purpose, and exe.dev VMs never expire.** Nothing in
  create/fill/setup/execute/observe ever calls `ssh exe.dev rm`, and nothing auto-destroys a VM. A run
  you forget bills until you tear it down — `just sbx manage list` shows record state and VM liveness,
  and the run's tag is what fleet cleanup filters on.
