# Plan: verify the `just local ui` cleanup fix with a SAFE signal harness

## Context

The fix is ALREADY applied (uncommitted) in `just/local.just`, `ui` recipe:
both servers are background children of the recipe shell with captured pids
(`API_PID`, `VITE_PID`), a `trap 'kill $API_PID $VITE_PID 2>/dev/null' EXIT INT TERM`,
and a final `wait`. The prior verification (spec `c0d53d0a_ui-cleanup-trap.md`)
died because its harness signaled its OWN process group and the build chain
inherited the kill (exit 143). **The fix was never the problem — only the
harness.** This plan re-runs the verification with a hardened harness. No repo
code changes.

## Environment facts (already confirmed by the planner)

- `SSSF_CONFIG` is exported: `adws/adw_sssf_config/sssf.hello.config.yaml`.
- Recorded port file `adws/adw_data/local/hello/ui.port` contains **4622**
  → vite on **:4622**, api on **:4623** (db `adws/adw_data/local/hello/sssf.db`).
- An UNRELATED hello server is live: `bun --hot server.ts` (pid 2048297) on
  **:4599**. It must NOT be signaled, killed, or counted as an orphan. The
  orphan patterns below (`server/index.ts`, `vite --port`) do not match it.
- `sandbox_mount/host/local_ui.py` exits **10** when a visualizer for this db
  is already running (URL printed to stderr); the recipe maps 10 → `exit 0`.
- No repo file may be edited. Scratch goes to `/tmp` only.

## Step 1 — Confirm the fix diff (read-only)

`git diff just/local.just` must show exactly these added lines in the `ui`
recipe (and nothing else in the file):

```
    SSSF_DB="$DB" PORT="$API_PORT" bun run server/index.ts & API_PID=$!
    PORT="$API_PORT" bunx vite --port "$UI_PORT" --strictPort & VITE_PID=$!
    trap 'kill $API_PID $VITE_PID 2>/dev/null' EXIT INT TERM
    wait
```

(with the two comment lines around them). If the diff differs, STOP and report
— do not "repair" it.

## Step 2 — Write `/tmp/verify_ui2.sh`

A bash script with these HARD safety rules (this is the whole point of the
resume):

1. Launch the recipe in its OWN session/group:
   `setsid just local ui >"$LOG" 2>&1 & CHILD=$!`
2. Derive the child's pgid from the kernel, never assume it:
   `PGID=$(ps -o pgid= -p "$CHILD" | tr -d ' ')`
3. Before ANY group signal (`kill -SIG -"$PGID"`), ASSERT:
   - `PGID` is non-empty and numeric, AND
   - `PGID` != the harness's own pgid (`ps -o pgid= -p $$ | tr -d ' '`), AND
   - `PGID` != the harness's own pid (`$$`).
   If the assert fails, DO NOT group-signal: fall back to a DIRECT
   `kill -INT "$CHILD"` (or `-TERM`) — the recipe's own trap still does the
   child cleanup, which is what is under test. Record which path was taken.
4. Treat the recipe exiting **130 or 143** after a signal as SUCCESS
   (128+SIGINT / 128+SIGTERM — the ctrl-C path), not as a harness failure.
5. Port checks use `ss -ltn | grep -E ':(4622|4623)\b'`; orphan checks use
   `pgrep -af 'server/index.ts'` and `pgrep -af 'vite --port'` (these never
   match the :4599 `bun --hot server.ts` — leave that process alone).
6. `set -u`; NOT `set -e` around the probe loops — collect failures into a
   FAIL counter and report at the end. Exit non-zero if any check fails.

## Step 3 — Run the demonstration (all evidence to `/tmp`, quoted into envelope)

Pre-flight: `ss -ltn` for 4622/4623 (expect free), `pgrep -af 'server/index.ts|vite --port'`
(expect empty). Record as BEFORE state.

**(a) Launch + listen.** Run `/tmp/verify_ui2.sh` launch phase: `setsid just
local ui`, poll `ss -ltn` (0.2s cadence, ~30s timeout — `bun install` may take
a moment) until BOTH :4622 and :4623 LISTEN. Capture `ss -ltnp` for both ports
(owning pids) as the LIVE state.

**(b) SIGINT cycle.** Group-signal per the safety rules (fallback: direct INT).
Assert within ~3s: recipe process gone; exit status 130 or 143 (from `wait`
on the child); BOTH ports closed; `pgrep -af 'server/index.ts'` and
`pgrep -af 'vite --port'` empty. Capture AFTER state. Log: `/tmp/ui2-int.log`.

**(c) SIGTERM cycle.** Fresh launch, wait for both ports, then SIGTERM (same
safety rules). Same assertions (143 expected). Log: `/tmp/ui2-term.log`.

**(d) Idempotent regression.** Fresh launch, wait for both ports. Then run a
SECOND `just local ui` in the foreground (same exported `SSSF_CONFIG`):
- expect the "already running: http://localhost:4622 …" line on **stderr**;
- expect **no** second instance: `ss -ltn` still shows exactly one listener
  per port;
- exit code: the recipe maps the resolver's 10 → `exit 0`, so rc=0 with the
  URL on stderr is the correct observable at the recipe level. (The prompt's
  "exits 10" is the RESOLVER-level signal; demonstrate that directly with
  `uv run sandbox_mount/host/local_ui.py "$SSSF_CONFIG"; echo rc=$?` → rc=10,
  and note the mapping in the envelope. If the recipe itself returns 10,
  record it and flag it — current code maps to 0.)
Then SIGINT the live instance (safety rules) and confirm the same cleanup
assertions as (b).

## Done means

(a)–(d) all green, with BEFORE/LIVE/AFTER `ss -ltn` (and `ss -ltnp`) state
quoted in the build envelope for each cycle, plus the pgid-assert evidence
(derived pgid vs harness pgid) showing the safe path was taken. The fix in
`just/local.just` is committed by THIS chain's commit phase; tree clean after.

## Out of scope

Everything else: no changes to `local_ui.py`, `just/local.just`, the
visualizer, or any other file. Do not touch the :4599 hello server
(pid 2048297). Do not commit — the chain's kind="code" commit phase owns the
commit; leave the tree as found (only `just/local.just` modified,
`specs/c0d53d0a_ui-cleanup-trap.md` and `adws/adw_sssf_config/sssf.meta9.config.yaml`
untracked).
