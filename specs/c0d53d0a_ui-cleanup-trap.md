# Plan: fix asymmetric process cleanup in `just local ui`

## Problem

In `just/local.just`, the `ui` recipe launches the API server double-detached:

```
(SSSF_DB="$DB" PORT="$API_PORT" bun run server/index.ts &)
```

The subshell detaches it into init, so ctrl-C / normal exit kills vite (the
foreground process) but NEVER the API server — its port (`UI_PORT+1`) stays
bound after the visualizer quits. Both ports must close on normal quit.

## File to touch

- `just/local.just` — the `ui` recipe only. Nothing else changes: the resolver
  call (`local_ui.py`), the exit-10 idempotency mapping, port allocation,
  `cd`, and `bun install` all stay byte-identical.

## The change

Replace the last two lines of the `ui` recipe

```
    (SSSF_DB="$DB" PORT="$API_PORT" bun run server/index.ts &)
    PORT="$API_PORT" bunx vite --port "$UI_PORT" --strictPort
```

with

```
    # Both servers are background children of THIS recipe shell with captured
    # pids; the trap kills both on EXIT/INT/TERM. (The old `( … & )` double-
    # detach orphaned the API server into init — ctrl-C killed vite but left
    # the API port bound.)
    SSSF_DB="$DB" PORT="$API_PORT" bun run server/index.ts & API_PID=$!
    PORT="$API_PORT" bunx vite --port "$UI_PORT" --strictPort & VITE_PID=$!
    trap 'kill $API_PID $VITE_PID 2>/dev/null' EXIT INT TERM
    # Residual limit: SIGKILL of the recipe still orphans the children
    # (untrappable) — acceptable; the parked general cleanup covers it.
    wait
```

Behavior notes (no extra code needed):

- SIGINT/SIGTERM: the trap fires, `wait` returns >128, the script ends, the
  EXIT trap fires again — `kill` with `2>/dev/null` is idempotent, so the
  double-fire is harmless.
- Normal exit (either server dies): `wait` returns, EXIT trap kills the
  survivor. Both ports close.
- The trap must be installed AFTER both pids are captured and BEFORE `wait`,
  exactly as written above.

## Verification (real, faithful ctrl-C simulation)

The recipe must run in its OWN process group so the test can signal the group
the way a terminal does. Use the hello roster:
`export SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`
(db: `adws/adw_data/local/hello/sssf.db`; port file: `adws/adw_data/local/hello/ui.port`, api = port+1). All scratch output goes to `/tmp`.

Pre-flight: `pgrep -af 'server/index.ts|vite'` and `ss -ltn` for the ports —
start clean (kill any strays from earlier manual runs first).

(a) Launch:
```
setsid just local ui >/tmp/ui-int.log 2>&1 &
PID=$!
PGID=$(ps -o pgid= -p $PID | tr -d ' ')
UI_PORT=$(cat adws/adw_data/local/hello/ui.port); API_PORT=$((UI_PORT+1))
```
Poll `ss -ltn` until BOTH `$UI_PORT` and `$API_PORT` listen (timeout ~30s;
`bun install` may take a moment). Record the listening pids via `ss -ltnp`.
Capture BEFORE state (both ports LISTEN + owning pids) for the envelope.

(b) `kill -INT -"$PGID"` (negative pid = process group, as a terminal sends).

(c) Assert within ~3s (poll loop, 0.2s cadence):
- recipe exited: `kill -0 $PID 2>/dev/null` fails
- BOTH ports free: `ss -ltn | grep -E ":(\$UI_PORT|\$API_PORT)\b"` empty
- no orphans: `pgrep -af 'bun.*server/index.ts'` and `pgrep -af 'vite --port'`
  return nothing for this instance
Capture AFTER state for the envelope.

(d) Repeat (a)–(c) with a fresh launch and `kill -TERM -"$PGID"` — same
assertions, same envelope evidence (log: `/tmp/ui-term.log`).

(e) Regression — idempotent second invocation:
- Launch once via `setsid` as in (a), wait for both ports.
- Run `just local ui` in the FOREGROUND (same SSSF_CONFIG). Expect: exit 0
  (recipe maps the resolver's exit 10 to 0), the URL line on stderr, and NO
  second instance started (`ss -ltn` still shows exactly one listener per
  port).
- Tear down with `kill -INT -"$PGID"` and confirm clean (same checks as (c)).

If any assertion fails, do NOT paper over it — report the failure.

## Done means

(a)–(e) demonstrated with before/after port state quoted in the envelope,
the fix landed in `just/local.just` by this chain, tree clean.

## Out of scope

Everything else — no changes to `local_ui.py`, other recipes, or the
visualizer app.
