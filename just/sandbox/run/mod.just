# just/sandbox/run/mod.just — put work into a mounted box, or look inside it.
#
# Two ways in, and they are not interchangeable:
#
#   just sbx run cmd    generic escape hatch, SYNCHRONOUS, prints stdout. Your
#                       inspection tool — a log, a git state, a table.
#   just sbx run agent  hand off to pi inside the box over a RESUMABLE session,
#                       then keep talking to it. For steering.
#
# The third way in is `just sbx lifecycle execute` — the detached full SDLC, and
# the default for real work. It lives with the phases because it writes `pid` to
# the run record; these two write nothing and are not phases.
#
# Nothing here ever destroys a VM. A failure reports and exits non-zero with the
# box left alive, because the evidence you need to diagnose it is on that box.
#
# No sandbox-minted credentials exist: the only host-only credential is the
# exe.dev account, and it never leaves the host. We also never ask ssh to forward
# host env (no SendEnv), so nothing from .env leaks over.
set working-directory := '../../..'
set positional-arguments
set dotenv-load

# list the ways into a sandbox
default:
    @just --list sbx::run

# usage: just sbx run cmd <run-id> uname -a   |   just sbx run cmd <run-id> "tail -20 run.log"
# generic escape hatch: run any command inside a sandbox, synchronously
cmd RUN_ID +CMD:
    #!/usr/bin/env bash
    set -euo pipefail
    RR="{{justfile_directory()}}/sandbox_mount/host/run_record.py"
    # The run record is the only cross-phase state; `get` fails loudly if the run
    # does not exist, which is the check we want before touching the network.
    VM=$("$RR" get {{RUN_ID}} vm_name)
    [ -n "$VM" ] || { echo "run cmd {{RUN_ID}}: no vm_name in the run record — is it mounted?" >&2; exit 1; }
    echo "→ run cmd {{RUN_ID}} on $VM: {{CMD}}"
    # {{CMD}} is interpolated verbatim rather than rebuilt from "$@" on purpose:
    # this is an escape hatch, so the pipes, globs and quotes you typed are meant
    # to reach the remote shell intact. `cd app` matches where FILL clones.
    # < /dev/null: any remote command that reads stdin would otherwise hang the
    # ssh session open on an interactive host TTY. stdout still streams locally.
    ssh "$VM".exe.xyz "cd app && {{CMD}}" < /dev/null

# usage: just sbx run agent <run-id> "remember the number 42, reply STORED"
#        just sbx run agent <run-id> "what number did I ask you to remember?"
# hand off to pi inside the sandbox, then keep talking to it
agent RUN_ID PROMPT:
    #!/usr/bin/env bash
    set -euo pipefail
    RR="{{justfile_directory()}}/sandbox_mount/host/run_record.py"
    VM=$("$RR" get {{RUN_ID}} vm_name)
    [ -n "$VM" ] || { echo "run agent {{RUN_ID}}: no vm_name in the run record — is it mounted?" >&2; exit 1; }
    SID=$("$RR" get {{RUN_ID}} session_id)
    [ -n "$SID" ] || { echo "run agent {{RUN_ID}}: no session_id in the run record — CREATE writes it" >&2; exit 1; }

    PROMPT={{ quote(PROMPT) }}
    Q=$(printf '%q' "$PROMPT")

    # pi, not Claude Code. There is no mirrored host model set: pi's built-in
    # catalog is keyed by app/.env (sourced below), and the FILL-shipped
    # settings.json points a bare `pi -p` at the roster's default provider/model.
    # --session-id CREATES the session if missing and CONTINUES it if it exists,
    # so ONE invocation works for every turn: the old first-turn vs subsequent-turn
    # sentinel (`--session-id` vs `--resume`) is gone entirely. Synchronous by
    # design: the whole point is to read the reply and send the next turn.
    echo "→ run agent {{RUN_ID}} on $VM: pi session $SID"
    # < /dev/null: pi -p ignores stdin but needs EOF to exit; an interactive host
    # TTY otherwise pins the ssh session open after the turn completes (stdout
    # keeps streaming locally — the lane stays synchronous by design).
    ssh "$VM".exe.xyz "cd app && if [ -f .env ]; then set -a; . ./.env; set +a; fi; pi -p --session-id $SID $Q" < /dev/null
