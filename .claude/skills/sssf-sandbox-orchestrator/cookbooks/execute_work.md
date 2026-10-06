# Execute work in a mounted sandbox

Three recipes drive a mounted sandbox. They are not interchangeable — pick by **how long the work takes
and whether you intend to stay**.

| Recipe | Shape | Runs | Pick it when |
|---|---|---|---|
| `just sbx run cmd <id> '<cmd>'` | synchronous, prints stdout | any command, in `app/` | inspecting, debugging, one-off shell work |
| `just sbx lifecycle execute <id> "<prompt>"` | **detached**, returns a pid | a `just adw` chain (default `sdlc`) | the default: real work, we walk away |
| `just sbx run agent <id> "<prompt>"` | synchronous, **resumable pi session** | one pi turn inside the box | steering, asking, iterating without ssh-ing in |

`execute` and `run agent` are the two **kickoff paths** — direct (a command) versus agent-mediated (a
delegation to the in-box agent). When the choice between them is the question, read
[references/kickoff_paths.md](../references/kickoff_paths.md). When delegating work through `run
agent`, give the delegate its briefing on the first work turn: this kernel has **no factory skill**, so
the delegate's briefing is the repo's own `README.md` plus `just --list adw`, e.g.
`If you have not already: READ README.md and run just --list adw. Then: <the work>` (the delegation
contract, same reference).

All three read `vm_name` from the run record, so the run must be mounted. None of them ever destroys a
VM: a failure reports, exits non-zero, and leaves the box up because the evidence is on it. None of
them touches a host secret — the provider keys stay in `app/.env` on the box where FILL put them.

## `just sbx run cmd` — the escape hatch

```bash
just sbx run cmd <run-id> uname -a
just sbx run cmd <run-id> 'tail -30 run.log'
just sbx run cmd <run-id> 'git log --oneline -5'
just sbx run cmd <run-id> 'sqlite3 adws/adw_data/sssf.db "select adw_id,status from sessions;"'
```

It runs `ssh <vm>.exe.xyz "cd app && <cmd>"`. Two consequences:

- **`cd app` is implicit** — every path is relative to the factory clone on the VM.
- **`{{CMD}}` is interpolated verbatim**, not rebuilt from `"$@"`. That is the point: pipes, globs and
  quotes you typed are meant to reach the remote shell intact. It also means you own the quoting.
  Single-quote anything containing `$`, `*` or `"` that the *remote* shell should see.

Synchronous, so `tail -f` blocks until you Ctrl-C. That is fine and often what you want.

## `just sbx lifecycle execute` — the default

```bash
just sbx lifecycle execute <run-id> "add a word-count badge to the editor footer"
```

```
→ roster: /home/exedev/sssf_config.yaml
→ execute <run-id> on <vm> (detached): adw sdlc add a word-count badge to the editor footer
→ pid 1542 recorded; SDLC is running detached
→ watch it:  just sbx run cmd <run-id> 'tail -f run.log'
```

Returns immediately. What it actually runs on the VM:

```bash
cd app && ( nohup just --shell bash --shell-arg -c adw sdlc <prompt> --config <roster> > run.log 2>&1 < /dev/null & echo $! )
```

Every piece is mandatory:

- **`nohup`** survives the ssh session ending, **`> run.log 2>&1`** releases stdout/stderr,
  **`< /dev/null`** releases stdin. Drop any one and ssh never returns.
- **`--shell bash --shell-arg -c`** — the root justfile sets `shell := ["zsh", "-ic"]` and zsh is not in
  the exeuntu image. The sandbox's default `sh` is dash, which also cannot parse the module's `${@:2}`.
- **`echo $!`** inside the subshell is the only way to get the pid back; `| tail -n 1` on the host side
  protects the capture from any stray remote stdout.
- The prompt makes two hops (just → host bash → remote login shell), so it is quoted twice:
  `{{ quote(PROMPT) }}` then `printf '%q'`. Apostrophes in a prompt survive.

The pid is written to the run record. A non-numeric answer is rejected on the spot rather than recorded
as garbage.

Two things to know:

- **`run.log` is truncated on every `execute`.** One detached SDLC per sandbox at a time is the
  intended shape. Pull the old log first if you care about it.
- **A recorded pid means "spawned", not "working".** `nohup … & echo $!` prints a pid even for a process
  that dies a millisecond later — a justfile parse error, for instance. Always confirm against
  `run.log` before telling anyone the run is underway.

### The 4-argument signature

```
just sbx lifecycle execute RUN_ID PROMPT [CONFIG] [ADW] [*EXTRA]
```

- **`CONFIG`** (3rd positional) picks the roster. It defaults to the per-sandbox copy FILL shipped at
  `/home/exedev/sssf_config.yaml`; a missing file is a hard failure, never a silent fall back to a repo
  default. A fan-out with a per-arm roster passes it here.
- **`ADW`** (4th positional) picks **which** `just adw` recipe runs — `sdlc` (default), `simple-sdlc`,
  `plan-build-test-quality`, `scout`, … A different chain is just a different 4th argument. Leave the
  3rd empty to keep the shipped roster:

  ```bash
  just sbx lifecycle execute <run-id> "add a word-count badge" "" simple-sdlc
  ```

- **`*EXTRA`** is appended verbatim after the config, for the ADW's own flags — most usefully
  `--adw-id <id>`, which rejoins an existing session so the agents keep their pi context.

### Running any other ADW by hand

`execute` picks any chain through its `ADW` argument. When you want a one-off through the shell instead
— a `plan` before deciding to `build`, say — `run cmd` remains the escape hatch:

```bash
just sbx run cmd <run-id> 'just --shell bash --shell-arg -c adw scout "where does auth live"'
just sbx run cmd <run-id> '( nohup just --shell bash --shell-arg -c adw simple-sdlc "..." > run.log 2>&1 < /dev/null & echo $! )'
```

Keep all three detachment pieces if you want it detached.

### Watching a detached run

```bash
just sbx run cmd <run-id> 'tail -f run.log'            # live, blocks until Ctrl-C
just sbx run cmd <run-id> 'tail -40 run.log'           # a snapshot, non-blocking

# still alive? ask about the pid the record holds
PID=$(sandbox_mount/host/run_record.py get <run-id> pid)
just sbx run cmd <run-id> "ps -o pid,etime,command -p $PID"
```

`run.log` is the SSSF console transcript (this example is illustrative):

```
▶ 02 plan  agent · planner  Turn the request into an implementable plan
  ▸ planner openrouter/google/gemini-3.6-flash  session sssf-84b6551f-planner-dee5
  ✓ gate artifacts_exist 2 checked
  └ planner used 685,426 tokens · $0.5172
  ✓ plan 82.6s
▶ 03 build  agent · builder  Implement the plan exactly
  ▸ builder openrouter/deepseek/deepseek-v4-flash-0731  session sssf-84b6551f-builder-457b
  └ builder used 217,405 tokens · $0.0108
  ✓ build 110.2s
▶ 04 test_1  code · quality  Run the suite
  · quality tests: passed (exit 0, 0.3s)
▶ 05 commit  code · git
  · sha: bcfc678, message: Add word-count target progress bar under editor footer
╭───────── ADW complete ──────────╮
│  status   ✓ success             │
│  phases   5/5 passed            │
│  tokens   902,831               │
│  cost     $0.5280               │
│  adw_id   84b6551f              │
╰─────────────────────────────────╯
```

The `adw_id` printed near the top of the log is the handle for every trace query — see
[observe_and_report.md](observe_and_report.md) for reading progress out of the db instead of the log.

## `just sbx run agent` — pi, resumable

```bash
just sbx run agent <run-id> "remember the number 42, reply STORED"
just sbx run agent <run-id> "what number did I ask you to remember?"     # -> 42
```

Verified working across **separate ssh invocations**: the second call is a new connection, a new shell
and a new `pi` process, and it still has the first turn's context.

What it runs:

```bash
cd app && ( if [ -f .env ]; then set -a; . ./.env; set +a; fi; pi -p --session-id <uuid> "<prompt>" )
```

- **`--session-id` CREATES the session if missing and CONTINUES it if it exists**, so one id drives
  every turn — there is no first-turn sentinel and no `--resume` branch to get wrong.
- **The session uuid is minted once, at `create`**, and lives in the run record.
- **`app/.env` is sourced first** so pi's built-in providers find their keys; there is no mirrored host
  model set. A bare `pi -p` lands on the roster's default provider/model because FILL wrote
  `~/.pi/agent/settings.json`.
- **Synchronous by design.** The whole point is to read the reply and send the next turn.

Use it when you want to *steer* — inspect a failed build, ask what a file does, make a small fix —
without ssh-ing in and losing the thread between commands.

## Choosing, in one paragraph

Start with `execute`: it is the factory, it is detached, and walking away is the entire premise of the
system. Reach for `agent` when the next step needs judgment and you want a conversation that survives
between commands. Reach for `run` when you want to *look* at something — a log, a git state, a port, a
table — and nothing more.
