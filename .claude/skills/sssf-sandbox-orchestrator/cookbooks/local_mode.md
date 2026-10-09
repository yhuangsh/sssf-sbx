# Local development — the `just local` lane

You are the **orchestrator**, booted by

```bash
just local orch cc adws/adw_sssf_config/sssf.<app>.config.yaml
# or
just local orch pi adws/adw_sssf_config/sssf.<app>.config.yaml
```

The roster argument is **mandatory**, and "focus" is what it buys: this whole session targets the app
that roster's `app:` block names. Orient on that app before you run anything else — the roster is the
per-app input, and every downstream command reads it.

This is the **local** lane. Everything runs on THIS machine, against a clone of the app at
`app.local_path`. There is no VM, no ssh, no exe.dev, and nothing to provision, observe, or tear
down. The workflow is otherwise identical to the sandbox lane: same chains, same gates, same
GitHub-issue tracking, same trace.

## The working rule: `SSSF_CONFIG` is already exported

`just local orch cc|pi <roster>` validated the file, resolved it to an absolute path, and **exported
`SSSF_CONFIG` into this session's environment**. That export wins over any `SSSF_CONFIG` in `.env`.

So every roster-consuming just command **just works** — do not set, unset, or override `SSSF_CONFIG`,
and never pass a different roster:

```bash
just local doctor                          # preflight + arming visibility
just local mount <run-id>                  # clone-if-missing, run branch, run record
just local execute <run-id> sdlc "<prompt>"   # the full SDLC, FOREGROUND — watch it live
just local ui                              # the trace visualizer
just adw ...                               # only ever DRIVEN through `just local execute`
just obs sessions                          # roster queries
```

The boot banner printed `roster:  <absolute path> (SSSF_CONFIG exported)`, `app.local_path`, and the
app — that is your handle. If you ever need to see it again, `echo "$SSSF_CONFIG"`.

## Orient on the app

1. **Read the roster's `app:` block.** It is the per-app input:

   ```yaml
   app:
     repo: https://github.com/…/<app>.git   # the app repo `mount` clones from when needed
     ref: main                              # the ref the clone is checked out at
     path: target                           # (target-mode shape; unused for the local payload)
     manifest: sssf.app.yaml                # the app's manifest, carried by the app repo
     local_path: /Users/you/projects/<app>  # LOCAL mode: the clone this lane runs against
   ```

   - `local_path` present → **local mode**. The payload is that clone, and it must live **OUTSIDE**
     this kernel tree — the kernel is never the payload of an app run.
   - No `local_path` → this is not a local roster; use `just sbx …` for the sandbox lane, or run
     `just local scaffold` to produce a local one.

2. **Read the app's `sssf.app.yaml`** at `<local_path>/sssf.app.yaml` — it declares the runtime,
   install, `serve:` block and `checks:`. You can read it directly on disk; there is no box to ask.

## Preflight, then mount

1. **Preflight first** — it resolves the roster through the same guard and checks the host tools, the
   provider keys, and the payload:
   ```bash
   just local doctor
   ```
   A `FAIL` means report and stop, never work around it.

2. **Mount** — `mount` resolves `app.local_path` (error if it points inside the kernel), clones the
   app from `app.repo` when the clone is missing, verifies the manifest and a clean tree, arms the
   clone (`sssf/` added to its `.gitignore`, committed on the run branch), creates the run branch
   `local/<run-id>` in the clone, and writes the run record (`vm_name: local`) into the state root
   (`<local_path>/sssf/runs/`):
   ```bash
   just local mount <run-id>
   ```
   **Report the run id it prints** — it is the handle for every later command. `mount` also prints
   the resolved payload path; use it when steering the agents.

## Develop via the execute lane

- **`just local execute <run-id> sdlc "<prompt>"`** — the factory: the full SDLC with gates, reviews,
  and commits to the run branch `local/<run-id>` in the clone. **Foreground**: it runs in your terminal
  and you watch it live. There is no detachment and no watcher. The default chain is `sdlc`; pass any
  recipe name from `just adw` as the second argument (`simple-sdlc`, `plan-build-test-quality`, …).
- **Never run `just adw …` on its own** (hard rule 2) — work enters through `just local execute`, so
  the issue hooks, the run branch, and the trace all stay in the loop.
- Commits land **directly** on `local/<run-id>` in the clone, including the run's `specs/` and
  `app_docs/` products (payload-aware commit routing). You push when ready; nothing is harvested
  or bundled.

See [execute_work.md](execute_work.md) for picking a chain and the delegation contract.

## Watch the trace

- **`just local ui`** serves the shipped visualizer against **this project's** trace db — the state
  root's `sssf.db` (`<local_path>/sssf/sssf.db`) — and prints which db it serves. It records a stable
  per-project UI port in `<db dir>/ui.port` (allocated from 4620 upward; the API runs on port+1); a
  re-run against a live instance prints the URL and exits 0. `just obs …` reads the same db.

## Issues, and the boundary

- GitHub issues open/close exactly like the sandbox lane — the instruction verbatim before the chain,
  the outcome after — but labeled **`sssf:local`** and with no VM fields. `just local execute` does
  this for you; `just sbx manage sync-issues` reconciles anything left open.
- There is **no teardown**. The run branch `local/<run-id>` in the clone is the boundary: **`git switch
  main`** in the payload (or just leaving the branch) is the cleanup. The kernel tree is never the
  payload and is never committed to by an app run; all run state (records, db, sessions, artifacts)
  lives under `<local_path>/sssf/`.

See `README.md → "Local development — just local"` for the tradeoffs vs the sandbox lane.

## Resume this session

- **pi:** re-run the exact same `just local orch pi <roster>` command. The recipe derives a
  deterministic session id from the roster basename, prefixed `local-` (`sssf.hello.config.yaml` →
  `local-hello`), and passes it via `--session-id`, which creates-or-continues — so you land back in
  this orchestrator's context. The sandbox lane uses the `orch-` prefix, so the two never share a
  session.
- **cc:** run `claude --dangerously-skip-permissions --continue` from this repo root to continue the
  most recent local orchestrator conversation (session-local, unlike pi's deterministic id).

See [just_command_model.md](just_command_model.md) for the recipe surface and the repo `README.md →
Orchestrator` for the boot/resume summary.
