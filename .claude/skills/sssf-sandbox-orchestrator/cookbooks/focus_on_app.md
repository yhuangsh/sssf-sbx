# Focus on the app this roster names

You are the **orchestrator**, booted by

```bash
just sbx orch cc adws/adw_sssf_config/sssf.<app>.config.yaml
# or
just sbx orch pi adws/adw_sssf_config/sssf.<app>.config.yaml
```

The roster argument is **mandatory**, and "focus" is what it buys: this whole session targets the app
that roster's `app:` block names. Orient on that app before you run anything else — the roster is the
per-app input, and every downstream command reads it.

## The working rule: `SSSF_CONFIG` is already exported

`just sbx orch cc|pi <roster>` validated the file, resolved it to an absolute path, and **exported
`SSSF_CONFIG` into this session's environment**. That export wins over any `SSSF_CONFIG` in `.env`.

So every roster-consuming just command **just works** — do not set, unset, or override `SSSF_CONFIG`,
and never pass a different roster:

```bash
just sbx manage doctor                      # preflight + arming visibility
just sbx mount <run-id>                     # the chain
just sbx lifecycle create|fill|setup|teardown <run-id>
just sbx manage harvest <run-id>
just adw ...                                # only ever DRIVEN through a sandbox phase
just obs sessions                           # roster queries
```

The boot banner printed `roster:  <absolute path> (SSSF_CONFIG exported)` and the app — that is your
handle. If you ever need to see it again, `echo "$SSSF_CONFIG"`.

## Orient on the app

1. **Read the roster's `app:` block.** It is the per-app input — four keys:

   ```yaml
   app:
     repo: https://github.com/…/<app>.git   # set -> FILL clones it to ~/app/<path> (target mode)
     ref: main                              # the ref FILL checks out
     path: target                           # where the app lands in the VM and on disk
     manifest: sssf.app.yaml                # the app's manifest, carried by the app repo
   ```

   - `repo` present → **target mode**: the app is a separate, external repo. The run branch
     `sbx/<run-id>` and every ADW commit live on that clone.
   - `repo` absent → **vendored mode**: the payload lives in this factory clone at `app.path`.

2. **Read the app's `sssf.app.yaml`** — the manifest is where the app declares its runtime, install
   and `serve:` blocks and its `checks:`. Get it one of two ways:
   - **Target mode, before a sandbox exists:** clone the app to scratch and read it there —
     `/tmp/<app>` (never into this repo, and use the roster's `ref`):
     ```bash
     git clone --depth 1 --branch <ref> <repo> /tmp/<app> && cat /tmp/<app>/sssf.app.yaml
     ```
   - **After mount:** read it inside the box, at `~/app/<path>/sssf.app.yaml`:
     ```bash
     just sbx run cmd <run-id> 'cat <path>/sssf.app.yaml'
     ```
   - **Vendored mode:** the manifest is local — `<app.path>/sssf.app.yaml` in this repo.

## Mount if no sandbox is up

1. **Preflight first** — it resolves the roster through the same guard and prints arming visibility:
   ```bash
   just sbx manage doctor
   ```
   A `FAIL` means report and stop, never work around it. In vendored mode the arming line tells you if
   the kernel is UNARMED (`app.path <path> missing`) and names the fix; that warning never affects the
   exit code.

2. **Mount** — the chain runs arming preflight → create → fill → setup (gate A–E) → observe:
   ```bash
   just sbx mount <run-id>
   ```
   It stops at `observe` on purpose; it never tears down. **Report the run id it prints** — `create`
   appends `-<date>-<6 hex>` if you did not, and that full string is the handle for every later phase.

## Develop via the execute lane

- **`just sbx lifecycle execute <run-id> "<prompt>"`** — the factory: the full SDLC with gates,
  reviews, and commits to the run branch `sbx/<run-id>`. Detached; returns a pid. This is where real
  work goes. The default chain is `sdlc`.
- **`just sbx run agent <run-id> "<prompt>"`** — steering: ONE pi turn inside the box, resumable
  `--session-id`, no chains or gates. Use it to ask, iterate, or hand off.
- **Never run `just adw …` on the host** (hard rule 2) — work enters a box through one of the two
  recipes above, always.

See [execute_work.md](execute_work.md) for picking between them and for the delegation contract.

## Observe, harvest, teardown

- **Watch:** `just sbx run cmd <run-id> '<cmd>'` (inspection) and the `observe` URLs; the trace UI on
  `:4600` and `just obs …` read the run's progress. See [observe_and_report.md](observe_and_report.md).
- **Harvest freely:** `just sbx manage harvest <run-id>` is non-destructive and idempotent — run it as
  soon as a run commits; it only reads the box and writes `refs/sandbox/<run-id>`.
- **Teardown is the human's call** (hard rule 1): `just sbx lifecycle teardown <run-id>` is the only
  destructive recipe. Report what the run produced and what it cost, recommend — then let the human
  decide. See [teardown_and_reap.md](teardown_and_reap.md).

## Resume this session

- **pi:** re-run the exact same `just sbx orch pi <roster>` command. The recipe derives a deterministic
  session id from the roster basename (`sssf.hello.config.yaml` → `orch-hello`) and passes it via
  `--session-id`, which creates-or-continues — so you land back in this orchestrator's context.
- **cc:** run `claude --dangerously-skip-permissions --continue` from this repo root to continue the
  most recent orchestrator conversation (session-local, unlike pi's deterministic id).

See [mount_one.md](mount_one.md) for the mount chain, [just_command_model.md](just_command_model.md)
for the recipe surface, and the repo `README.md → Orchestrator` for the boot/resume summary.
