# Orchestrator boot takes a mandatory roster — focus on one app

`just sbx orch cc` / `just sbx orch pi` no longer boot a generic orchestrator. They take a
**mandatory** positional roster file, validate it, absolutize it, export it as `SSSF_CONFIG` into the
launched agent's environment, and print a banner naming the roster plus the app it targets. A new
`focus_on_app.md` cookbook tells the freshly-booted orchestrator how to orient on that app, and the
SKILL / `just_command_model` docs are congruence-passed to match. README gains an `### Orchestrator`
subsection summarizing boot + resume for both harnesses.

## Why it matters

Before, `just sbx orch cc` booted Claude Code with just the skill URL in the prompt — no roster, no
export, no focus. The orchestrator had to know to set `SSSF_CONFIG` itself, and `.env` was the only
ambient source. That made the boot target-agnostic by default and easy to mis-target with a stale
`.env`.

Now the roster is the **per-app input**: the boot *is* the focus. The mandatory positional makes
running without a roster a usage error, the export makes every roster-consuming `just` command the
session runs hit the same roster (overriding any `.env`), and the deterministic pi session id
(`orch-<roster-name>`) means re-running the same command resumes the same orchestrator context.

## Where the change lives

- **`just/sandbox/orch/mod.just`** — the core change. Header comment now reflects the
  `cc <roster>` / `pi <roster>` shape and explains why the roster is mandatory. The two recipes are
  rewritten as `#!/usr/bin/env bash` bodies that share a ~20-line prologue (validate → absolutize →
  export `SSSF_CONFIG` → parse `app.repo`/`app.path` via the established awk idiom → print banner →
  launch) and differ only in the resume mechanism and the launch line. A header comment above the
  recipes documents the `cc` resume story (`claude --dangerously-skip-permissions --continue` from
  the repo root, session-local) and reminds that the cc/pi bodies must stay in sync. Trailing
  history note updated to reference the new shape.

  Validation message is exact: `[orch] roster file '<path>' not found` (stderr, exit 1, nothing
  launched). Absolutization uses `cd "$(dirname …)" && pwd` / `basename` rather than `realpath` for
  portability. The `app:` parser reuses the exact awk pattern from `just/sandbox/mount.just` and
  `just/sandbox/lifecycle/create.just` — no `yq` on the host.

  The kickoff prompt is intentionally **thin** in both recipes:
  `Read and execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md, then the cookbook
  .claude/skills/sssf-sandbox-orchestrator/cookbooks/focus_on_app.md. SSSF_CONFIG is already
  exported and names your roster: <abs path>. Every roster-consuming just command uses it — do not
  set or override it.`

- **`.claude/skills/sssf-sandbox-orchestrator/cookbooks/focus_on_app.md`** — NEW. The instructive
  cookbook the kickoff prompt points at. Sections: the `SSSF_CONFIG` working rule (every
  roster-consuming command "just works"; never set/override/pass a different roster); orient on
  the `app:` block (`repo`/`ref`/`path`/`manifest`); read `sssf.app.yaml` (target mode → clone to
  `/tmp/<app>` or read after mount; vendored mode → local); preflight then `just sbx mount
  <run-id>`; develop via `lifecycle execute` (the factory) or `run agent` (steering); observe +
  harvest freely, teardown is the human's call; resume (pi = re-run; cc = `--continue`). Cross-links
  `mount_one.md`, `execute_work.md`, `observe_and_report.md`, `teardown_and_reap.md`,
  `just_command_model.md`, and `README.md → Orchestrator` instead of re-teaching them.

- **`.claude/skills/sssf-sandbox-orchestrator/SKILL.md`** — congruence pass. Adds one line in the
  `SSSF_CONFIG is required` section noting `just sbx orch cc|pi <roster>` exports it for the whole
  session (explicit arg wins over `.env`); updates the drive-surface tree to
  ``orch cc <roster>`, `orch pi <roster>``; adds a row to the cookbook table pointing at
  `focus_on_app.md` for "Orient on the app this roster names".

- **`.claude/skills/sssf-sandbox-orchestrator/cookbooks/just_command_model.md`** — namespace row in
  the two-layers table updated to include ``just sbx orch cc <roster>`, `just sbx orch pi <roster>``.

- **`README.md`** — new `### Orchestrator` subsection at the tail of `## Use`. Covers boot (the
  roster is mandatory; validates, exports `SSSF_CONFIG` overriding `.env`, prints `app.repo`/
  `app.path`), what "focus" means (orient on the app → mount → execute → steer → harvest →
  human-decides teardown), and resume for both harnesses. Commands verified against the recipes.

- **`specs/67997a39_orch-roster-focus.md`** — the spec the build followed. Kept in the tree as a
  record of the plan and the verification gates (a–e).

## How to use it

```bash
# Boot Claude Code focused on a roster's app
just sbx orch cc adws/adw_sssf_config/sssf.hello.config.yaml

# Boot pi on the same roster
just sbx orch pi adws/adw_sssf_config/sssf.hello.config.yaml

# Resume later — pi
just sbx orch pi adws/adw_sssf_config/sssf.hello.config.yaml   # same command; --session-id orch-hello

# Resume later — cc
claude --dangerously-skip-permissions --continue                # from the repo root
```

Inside the launched session, every roster-consuming command reads `SSSF_CONFIG` from the exported
value (`echo "$SSSF_CONFIG"` to see it):

```bash
just sbx manage doctor
just sbx mount <run-id>
just sbx lifecycle create|fill|setup|teardown <run-id>
just sbx manage harvest <run-id>
just adw ...            # only via a sandbox phase, never on the host
```

The orchestrator's first move should be to read `.claude/skills/sssf-sandbox-orchestrator/
cookbooks/focus_on_app.md` (the kickoff prompt already points there).

## How to verify it

These are the gates the build ran; reviewer can re-run them.

1. **List shape.** `just sbx orch` lists `cc`, `pi`, `default`; `just --list sbx::orch` shows the
   `SSSF_CONFIG_FILE` positional in usage.
2. **Mandatory arg + missing file.**
   - `just sbx orch cc` (no arg) → just's usage error, non-zero exit.
   - `just sbx orch pi /nonexistent.yaml` → stderr contains
     `[orch] roster file '/nonexistent.yaml' not found`, exit 1, no agent launched.
3. **Pi resume, live.** With `adws/adw_sssf_config/sssf.hello.config.yaml`, derive the session id
   via the recipe's exact logic (`sssf.hello.config.yaml` → `orch-hello`), then:
   ```bash
   pi -p --session-id orch-hello "This orchestrator's roster is adws/adw_sssf_config/sssf.hello.config.yaml and the app it builds is hello-server. Remember the app."
   pi -p --session-id orch-hello "what app does this orchestrator build? answer from memory"
   ```
   The second reply must name `hello-server` from the first turn's context (proves
   create-or-continues). Confirm `git status --short` is clean afterwards (pi stores sessions
   under `~/.pi`).
4. **Kickoff prompt inspectable.** `just --show sbx::orch::cc` and `just --show sbx::orch::pi`
   print the recipe source including the full prompt string. Do **not** launch interactive
   `claude`/`pi` from the build.
5. **Cookbook / README congruence.** Every command in `cookbooks/focus_on_app.md` and
   `README.md → Orchestrator` matches the recipes — names, arg order, resume commands.
