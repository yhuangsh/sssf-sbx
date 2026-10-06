# Access a running sandbox

Trigger: **the user wants to access the running sandbox** — "get me into the box", "give me a terminal
in there", "let me talk to the agent inside", "attach me to the run".

Two flows, chosen by what the user wants to touch:

| Flow | The user wants | Mechanism |
|---|---|---|
| **A — shell access** | a terminal inside the box | `ssh <vm>.exe.xyz` from their own terminal |
| **B — join the agent** | to talk to the in-box pi session | `ssh -t <vm>.exe.xyz` + `pi --session-id <recorded id>` |

Both start the same way: resolve the VM from the run record, because the run id is the handle and the
record is the only truth about which box it names.

```bash
VM=$(sandbox_mount/host/run_record.py get <run-id> vm_name)
[ -n "$VM" ] || echo "not mounted — no vm_name in the record"
```

Neither flow is destructive, neither touches a secret, and neither needs a new credential: the host's
exe.dev SSH access is the whole mechanism. What these flows hand the user is a **live interior** —
remind them the box is disposable, the factory clone in `app/` is where the run lives, and anything
worth keeping leaves via `just sbx manage harvest`, not via copy-paste from a shell.

## Flow A — a shell in the box

The mechanism is just the host's own ssh access. Give the user the address (or open it in a second
terminal / their preferred multiplexer; this skill does not own a terminal surface):

```bash
ssh $VM.exe.xyz
```

Then, once they are in, confirm the shell landed where the work is:

```bash
cd app          # the factory clone root — FILL put the whole repo here
ls              # in target mode the app payload is a separate clone at app/<app.path>
```

`app/` is the factory (toolbelt) clone in every mode; in **target** mode the app the run commits to is
the target clone at `app/<app.path>`, and the run branch `sbx/<run-id>` lives on it. Hand it over and
**stop typing into it** — it is their shell now. When the box dies (teardown), the ssh session ends.

## Flow B — connect to the in-box pi session

The box's steering agent is a **resumable pi session**: its `session_id` was minted at CREATE and lives
in the run record; `just sbx run agent` has been the host's way of talking to it one turn at a time.
This flow joins that same session interactively.

1. **Resolve both handles:**

   ```bash
   VM=$(sandbox_mount/host/run_record.py get <run-id> vm_name)
   SID=$(sandbox_mount/host/run_record.py get <run-id> session_id)
   ```

2. **Attach interactively.** `ssh -t` is mandatory — pi's interactive UI needs a TTY, and
   `ssh vm "cmd"` does not allocate one. `--session-id` creates-or-continues, so this picks up exactly
   where `just sbx run agent` left off (same id, `-p` dropped for the interactive form):

   ```bash
   ssh -t $VM.exe.xyz "cd app && if [ -f .env ]; then set -a; . ./.env; set +a; fi; pi --session-id $SID"
   ```

3. **On exit,** the session remains resumable — from the terminal again, or from the host via
   `just sbx run agent <run-id> "..."`. Same session, same memory, two doors.

The host lane is unchanged: `just sbx run agent <run-id> "<prompt>"` sends one non-interactive turn
(`pi -p --session-id <id>`) and stays the right call when you do not need a TTY.

**What this flow is NOT:** the detached SDLC (`just sbx lifecycle execute`) is not an agent you can
join — it is a pid and a `run.log`. "Attach me to the build" means
`just sbx run cmd <run-id> 'tail -f run.log'`, and that belongs to
[observe_and_report.md](observe_and_report.md).

## Which flow, when

| The user says | Flow |
|---|---|
| "ssh me in", "give me a shell", "let me poke around" | A |
| "let me talk to the agent", "connect me to pi in there" | B |
| "how is the run going" | neither — [observe_and_report.md](observe_and_report.md) |
| "run this command in there for me" | neither — `just sbx run cmd`, [execute_work.md](execute_work.md) |
