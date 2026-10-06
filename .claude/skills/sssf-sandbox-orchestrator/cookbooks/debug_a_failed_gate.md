# Debug a Failed Gate

The SETUP gate (in `just/sandbox/lifecycle/setup.just`, step 3/3) runs five assertions against a
mounted sandbox. When one fails it **reports, stops, and leaves the VM running**. That is deliberate:
the evidence you need is on the box, and a gate that auto-destroys throws it away. Nothing in the
phases destroys a VM except `just sbx lifecycle teardown`, and teardown is always a separate human
decision.

So the first rule of debugging a gate failure is: **do not tear down.** Read the box.

## What the failure hands you

`gate_fail()` prints the assertion that failed and the starting commands:

```
[setup] FAILED: assertion B — pi stale, missing, or --list-models empty or 'No models available'
[setup] the VM is still running on purpose — the evidence is on the box:
[setup]   ssh <vm>.exe.xyz
[setup]   ssh <vm>.exe.xyz 'cd app && git status --porcelain'
[setup]   ssh <vm>.exe.xyz 'cd app && set -a && . ./.env && set +a && pi --list-models'
[setup] tear it down only when you are done: just sbx lifecycle teardown <run-id>
```

A and B run as their own remote scripts and fail on their own. C, D and E run as **one** remote script,
so the exit code names which one:

| Remote exit | Assertion | setup.just says |
|---|---|---|
| 2 | C | at least one roster model did not answer through pi |
| 3 | D | pi reported no cost on a live call |
| 4 | E | a roster provider's env key is unset |
| anything else | C/D/E prologue | the remote gate script exited N (see output above) — usually a missing `app/.env`, missing `jq`, or a missing `pi` |

## The two handles

Everything below uses one of these. There is no third source of truth.

```bash
RR=sandbox_mount/host/run_record.py
$RR get <run-id>                    # the whole record
VM=$($RR get <run-id> vm_name)      # the ssh target is $VM.exe.xyz
just sbx run cmd <run-id> '<cmd>'   # synchronous, already cd'd into app/
```

**Quoting rule for `just sbx run cmd`, verified:** `{{CMD}}` is interpolated verbatim into a
double-quoted ssh string, so any quoting that must survive to the VM has to be **single** quotes, and
any `$` the VM should expand has to be `\$`. `just sbx run cmd id "sqlite3 db 'select 1'"` reaches the
VM intact; `just sbx run cmd id 'sqlite3 db "select 1"'` arrives as `sqlite3 db select 1`. When a
command needs both nested quotes and remote `$` expansion, drop to
`ssh $VM.exe.xyz '<single-quoted script>'` — one layer of quoting instead of two.

---

## A — git integrity

**What it proves.** The clone landed *intact* and is the commit the run record says it is. Existence is
not the check — content is. An unsynced golden-VM `cp` once produced 5,641 zero-byte files and reported
success; truncation shows up in git as ` M path`, which is why this is `git status`, not a file count or
a hash manifest.

Two modes, because the roster's `app:` block decides what the payload is:

- **Target mode** (`app.repo` set): the **factory** clone's HEAD must match the recorded `factory_sha`
  (the toolbelt sha), and only the factory tree is asserted clean; the **target** clone at
  `~/app/<path>` must exist and its HEAD must match the recorded `commit_sha`. The target's tree is
  **not** asserted clean — provision's `bun install` may legitimately rewrite the target's `bun.lock`.
- **Vendored mode** (no `app.repo`): HEAD must match `commit_sha` (and `factory_sha` when the record
  carries one).

The configured `app.path`'s untracked-directory porcelain line (`?? <path>/`) is **filtered out** of the
clean-tree assertion. That entry is roster *data* — the target clone is expected to sit there — so a
custom app path needs **no `.gitignore` edit**. The filter drops exactly that one whole line and nothing
else.

**Failure looks like** one of:

```
   no ~/app on this VM — FILL never ran
   git rev-parse failed — .git is damaged
   factory HEAD <sha> does not match recorded factory_sha <sha>
   target <path> is not a git repository — FILL never cloned it
   target HEAD <sha> does not match the recorded commit_sha <sha>
   unexpected working-tree changes in the factory clone (the tree must be clean):
      M justfile
      M README.md
```

**Diagnose:**

```bash
$RR get <run-id> commit_sha
$RR get <run-id> factory_sha
just sbx run cmd <run-id> 'git rev-parse HEAD'
just sbx run cmd <run-id> 'git status --porcelain'
just sbx run cmd <run-id> 'git diff --stat'
# the zero-byte signature of an unsynced clone
just sbx run cmd <run-id> "find . -type f -empty -not -path './.git/*' | wc -l"
```

**Read it:**

- ` M` on tracked files, plus a non-trivial empty-file count → corrupt copy. Re-run
  `just sbx lifecycle fill <run-id> [sha]` or mount a fresh run. If it came from `cp`, you skipped
  `ssh <golden> sync`.
- A porcelain failure that is **only** `?? <app.path>/` → the app.path filter is broken, not your
  `.gitignore`. That line is expected content; the gate exists to drop it.
- HEAD mismatch with a clean tree → FILL checked out something else, or an ADW already ran in this box
  and committed. A run that has executed will fail A by design; A is a pre-execute check.
- ` D` lines on tracked paths → something deleted files in the clone. Nothing in provisioning removes
  anything, so treat it as damage and re-run `just sbx lifecycle fill <run-id>`.

---

## B — pi is current and `--list-models` is non-empty

**What it proves.** Two things: the pi on the box is the **registry latest** (provision step 4 must have
landed it), and pi's built-in providers loaded. pi's model set is not a shipped file any more — every
provider the rosters name is a pi **built-in**, keyed by the env vars FILL wrote to `app/.env`.

The check sources `app/.env` first, because `ssh host cmd` carries no environment and a fresh
`pi --list-models` lists nothing without the keys. It also runs `command -v pi` first, because a missing
binary prints one line of "command not found" and a bare non-empty check would call that a pass. And it
never trusts `$?`: `pi --list-models` **exits 0 while printing "No models available"**.

**Failure looks like:**

```
   pi is not on PATH
   npm view failed — cannot verify pi currency
   pi is 1.2.3, registry latest is 1.2.4 — provision step 4 did not land latest
   pi --list-models printed nothing
   pi says: No models available — app/.env was not sourced or holds no keys
```

**Diagnose:**

```bash
just sbx run cmd <run-id> 'set -a; . ./.env; set +a; pi --version; echo "exit=$?"'
just sbx run cmd <run-id> 'npm view @earendil-works/pi-coding-agent version'
just sbx run cmd <run-id> 'set -a; . ./.env; set +a; pi --list-models; echo "exit=$?"'
just sbx run cmd <run-id> 'ls -l .env'
```

**Read it:**

- Stale pi → re-run `just sbx lifecycle setup <run-id>` (provision reinstalls at `latest`); if the image
  is genuinely wedged, `just sbx lifecycle fill` then setup.
- "No models available" with a present `.env` → the `app/.env` keys are missing or wrong. Confirm the
  provider keys your roster needs are in the list FILL printed (`env keys: …`, names only), then re-run
  `just sbx lifecycle fill <run-id>`.
- `pi is not on PATH` on a stock exeuntu VM means something clobbered the image — pi ships at
  `/usr/local/bin/pi`. Suspect a bad `rm` before suspecting the image.

---

## C — every roster model answers a ping, through pi

**What it proves.** The credential works, the sandbox's own egress works, and every model id in the
**active** config resolves. Ids rot; this catches a retired or typo'd id before an agent burns a phase
on it.

Mechanically: the gate reads every `model: provider/id` line out of the active roster, splits on the
first slash into `--provider` / `--model`, and sends each a one-word prompt **through pi**
(`pi -p --no-tools --provider P --model M 'ping - respond with pong'`). Because it goes through pi, one
call verifies credential + `baseUrl` + api flavor + the built-in provider entry — which a single-provider
curl never could.

**Failure looks like:**

```
   pass  deepseek/deepseek-v4-flash-0731
   FAIL  zai/glm-5.2: pi returned no output (credential, baseUrl, api flavor, or provider entry)
```

**Diagnose.** First, see exactly which ids the gate pinged from the active roster:

```bash
just sbx run cmd <run-id> "awk '/^[[:space:]]*model:[[:space:]]/ {print \$2}' /home/exedev/sssf_config.yaml | sort -u"
```

Then reproduce one model by hand — a ping is exactly the gate's shape:

```bash
ssh $VM.exe.xyz
cd app && set -a && . ./.env && set +a
pi -p --no-tools --provider zai --model glm-5.2 'ping - respond with pong'
```

**Read it:** `FAIL <model>: pi returned no output` names one of four causes — the provider's **credential**
is missing in `app/.env`, its **baseUrl** is wrong, its **api flavor** is unsupported, or the model's
**provider entry** is not a pi built-in. Work them in that order; the fix for the first two is a
`.env` change on the host plus a re-`fill`, and the last is `roster_keys.sh`'s mapping needing the new
provider.

---

## D — pi reports NON-ZERO cost

**What it proves.** pi's built-in rate table loaded. This is the assertion people delete because it
"looks redundant with B," and it is the one that caught the most expensive bug in the system.

`adw_modules/agent_pi.py` reads `usage.cost.total` straight out of pi, and pi defaults every rate to
zero when it cannot price a model. A factory in that state runs perfectly and reports `$0.0000` forever
while genuinely spending money. Measured: a **463.6k-token run logged $0.0000**. So D makes a live call
on the roster's `defaults.model`, pulls cost out of pi's own `--mode json` output, and asserts it is
`> 0` — one sentence reports about `4.3e-05`, small but unambiguously positive.

**Failure looks like:**

```
   FAIL  pi reported cost 0 on a live call — every run would log
         $0.0000 while really spending money
```

**Diagnose:**

```bash
# the same call the gate makes, raw
just sbx run cmd <run-id> "set -a; . ./.env; set +a; timeout 180 pi -p --mode json --provider <provider> --model <model> 'Write one sentence about sandboxes.' | tail -n 3"
```

**Read it:**

- pi errors instead of answering → this is really a B or C failure wearing D's clothes. Fix those first.
- pi answers but `cost.total` is `0` → the model is not priced by the built-in catalog. A roster model
  just needs its **provider's env var in `.env`**; the built-in catalog carries baseUrl/api/cost. A
  provider or model pi does not know needs attention at the pi/provider level, not a hand-edited rate
  table here.

**jq, not python.** An unindented line inside a `just` recipe body TERMINATES the recipe, so a
multi-line python heredoc cannot survive there. `jq` ships in the exeuntu image; use it.

---

## E — every roster provider has its env key

**What it proves.** Each provider named in the roster has its credential in the sourced environment.
This is the coverage check for the whole roster, not just the model D happened to call.

The provider → env-var map is copied from pi's own `getApiKeyEnvVars`. It has **two copies** that must
stay in sync: `sandbox_mount/host/roster_keys.sh` (host, used by FILL and doctor) and gate E inside
`setup.just` (in-sandbox, because `roster_keys.sh` is not usable inside the box).

**Failure looks like:**

```
   credential present for deepseek (DEEPSEEK_API_KEY)
   FAIL  provider zai needs ZAI_API_KEY, unset in the sourced environment
   FAIL  provider someone-new is not a known pi built-in — no env-var mapping
```

**Diagnose:**

```bash
# what FILL shipped (names only — one line of evidence)
just sbx run cmd <run-id> 'grep -o "^[A-Z_]*=" .env | tr -d "="'
# the map on the host
sandbox_mount/host/roster_keys.sh "$SSSF_CONFIG"
```

**Read it:**

- `provider <p> needs <VAR>` → add `<VAR>` to your host `.env` (see `.env.sample`) and re-run
  `just sbx lifecycle fill <run-id>` then `just sbx lifecycle setup <run-id>`. FILL derives the
  required set from the roster and fails fast before shipping anything.
- `provider <p> is not a known pi built-in` → the map needs the new provider. Add it to
  `sandbox_mount/host/roster_keys.sh` **and** gate E in `setup.just`, or register the provider out of
  band. A model whose provider pi does not know cannot be gated.

### A note on config selection

`setup` takes a `CONFIG` argument and defaults to the per-sandbox copy FILL shipped at
`/home/exedev/sssf_config.yaml`; a missing file fails the gate rather than silently falling back to a
repo default. If a fan-out arm passes its own roster with
`just sbx lifecycle setup <id> <cfg>`, **that** roster is what C/D/E gate — the old "the gate always
pings the default" gotcha is gone. Pass the same path you passed to `just sbx lifecycle execute`.

---

## Two false failures already paid for

Both of these were healthy sandboxes that the system called broken. They are here because the shape
repeats.

### 1. Gate D diffed the wrong instrument

The first version of D read a provider's key usage before and after the C pings and asserted the delta
was non-zero. On the first live mount it failed — on a **correctly configured** sandbox: four 250-token
pings on cheap models round to zero at that endpoint's precision, so a working box looked broken.

The thing being guarded is whether **pi** reports cost, not whether the provider recorded it. D now
makes a real pi call and asserts pi's own reported number.

**The lesson generalizes: assert on the component you are guarding, at the precision it operates.** A
proxy metric that rounds to zero is a gate that fails randomly and gets deleted for being flaky.

### 2. `bun: No such file or directory` in OBSERVE

OBSERVE tried to start the app and got `bun: No such file or directory` — **minutes after provision.sh
had used bun successfully** on the same VM.

Cause: **each `ssh vm cmd` is a fresh non-interactive shell that reads no rc file.** The bun installer
only edits shell rc files; provision.sh worked because it did `export PATH="$HOME/.bun/bin:$PATH"`
inside its own process, and that died with the script. `just` was never affected because its installer
writes to `/usr/local/bin`.

Fix, now in `sandbox_mount/guest/provision.sh`: symlink `bun` and `bunx` into `/usr/local/bin`.

**Detect it in one command** — compare the non-interactive answer (the truth for everything the
orchestrator does) with the login-shell answer:

```bash
ssh $VM.exe.xyz 'command -v bun'                    # what the recipes see
ssh $VM.exe.xyz 'bash -lic "command -v bun"'        # what a human sees
```

If the first is empty and the second is not, you have this bug. It applies to **anything** installed
into a home directory: put it on `/usr/local/bin` or it does not exist as far as the orchestrator is
concerned. The same fact is why `--env` is useless for secrets (it lands in `/etc/profile.d/`) and why
`just` in the sandbox needs `just --shell bash --shell-arg -c` (the root justfile sets `zsh -ic`, and
zsh is not in the image; installing it is ~35s of apt for no benefit).

---

## Re-running the gate

`just sbx lifecycle setup <run-id>` is safe to re-run and is the normal fix loop. It removes
`/tmp/PROVISION_READY` first — otherwise a re-run would find the *previous* run's sentinel and declare
victory before provision.sh had done anything — then re-runs provision.sh, which is idempotent by
construction (skip-if-present installs, `CREATE TABLE IF NOT EXISTS` DDL).

For a fix that lives in the repo (a roster edit, a new provider in the key map), push it, then:

```bash
just sbx lifecycle fill  <run-id>          # fast-forwards app/ to origin/main; never resets over the run's own commits
just sbx lifecycle setup <run-id>
```

If provision.sh itself fails, its last `── step ──` line names the stage — the ERR trap prints
`[provision] FAILED during: <step>`.

## When to actually tear down

Only when you have what you need, and only because a human said so. The VM costs money while it sits,
but a destroyed VM costs the whole debugging session. If the box is unsalvageable,
`just sbx lifecycle teardown <run-id>` still pulls the artifact delta and the git bundle **before** it
destroys anything — see `teardown_and_reap.md`.
