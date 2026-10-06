# Plan: `just sbx orch cc|pi` takes a MANDATORY roster file

Make the orchestrator boot recipes require a roster (`SSSF_CONFIG_FILE`), resolve+validate it to an
absolute path, export it as `SSSF_CONFIG` into the launched agent's environment, print a boot banner
with the roster's `app:` block, and give each harness a resume story (deterministic `--session-id`
for pi, documented `--continue` for cc). Add the `focus_on_app.md` cookbook, congruence-pass the
skill docs, and add a README "Orchestrator" subsection.

## Background facts (already verified)

- `just/sandbox/orch/mod.just` sets `working-directory := '../../..'` (repo root), `positional-arguments`, `dotenv-load`. Current recipes `cc:` / `pi:` take no args and boot with the prompt `"Read and Execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md"`.
- The canonical `app:`-block awk parser already exists in `just/sandbox/mount.just` (and `create.just`) — reuse that exact pattern:
  ```bash
  APP_REPO=$(awk '
    /^app:[[:space:]]*$/      { a=1; next }
    /^[^[:space:]]/           { a=0 }
    a && /^[[:space:]]+repo:[[:space:]]/ { print $2; exit }
  ' "$ROSTER" 2>/dev/null || true)
  APP_PATH=$(awk '... same shape with path: ...' "$ROSTER" 2>/dev/null || true)
  ```
  No `yq`, no python yaml on the host — awk is the established roster-parse idiom in this repo.
- `just/sandbox/run/mod.just` documents the pi resume semantics to cite: "`--session-id` CREATES the session if missing and CONTINUES it if it exists".
- The hello roster for live verification: `adws/adw_sssf_config/sssf.hello.config.yaml` (`app.repo: https://github.com/yhuangsh/hello-server.git`, `app.path: target`). Host `pi` is installed (1.0.4); provider keys live in `.env` (dotenv-loaded by just; for the raw `pi` verification calls, source `.env` or rely on pi's own config).
- `.env` currently has `SSSF_CONFIG` commented out — the explicit param overriding `.env` must be provable by setting `SSSF_CONFIG` to a decoy inline.
- Tree is currently clean; `.sandbox/` holds old run artifacts — do not touch.

## Files to change

### 1. `just/sandbox/orch/mod.just` — the core change

Keep `default` and the settings block. Rewrite the header comment's usage lines
(`just sbx orch cc / pi` → `just sbx orch cc <roster>` / `pi <roster>`) and the trailing history
note so nothing describes booting without a roster.

Replace both recipes with mandatory-positional shebang-bash recipes. Shared body shape (per
recipe; just has no cross-recipe functions, so duplicate the ~20 lines with a comment noting the
cc/pi copies must stay in sync):

```
# boot the sandbox orchestrator (Claude Code), focused on this roster's app
cc SSSF_CONFIG_FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    # Validate BEFORE anything launches: the roster is the whole point of the boot.
    [ -f "{{SSSF_CONFIG_FILE}}" ] || { echo "[orch] roster file '{{SSSF_CONFIG_FILE}}' not found" >&2; exit 1; }
    # Absolute path: working-directory is the repo root, but the orchestrator cd's
    # around; a relative SSSF_CONFIG would silently break every roster-consuming
    # command after the first cd. cd/pwd, not realpath (portable).
    ROSTER="$(cd "$(dirname "{{SSSF_CONFIG_FILE}}")" && pwd)/$(basename "{{SSSF_CONFIG_FILE}}")"
    # EXPORT: every roster-consuming just command the agent runs (mount, fill,
    # doctor, harvest, adw …) must hit THIS roster. Exported here, it wins over
    # any SSSF_CONFIG dotenv-load pulled in from .env.
    export SSSF_CONFIG="$ROSTER"
    # app: block, same awk as mount.just/create.just (no yq on the host).
    APP_REPO=$(awk '...' "$ROSTER" 2>/dev/null || true)
    APP_PATH=$(awk '...' "$ROSTER" 2>/dev/null || true)
    # boot banner: harness, roster, app, resume
    printf '[orch] harness:  claude-code\n[orch] roster:   %s (SSSF_CONFIG exported)\n[orch] app.repo: %s\n[orch] app.path: %s\n[orch] resume:   claude --dangerously-skip-permissions --continue   (from this repo root; continues the most recent orchestrator conversation)\n' \
      "$ROSTER" "${APP_REPO:-<none — vendored mode>}" "${APP_PATH:-<unset>}"
    claude --dangerously-skip-permissions "<kickoff prompt, see below>"
```

The `pi` recipe is identical except:
- Session id derivation (deterministic, from the roster basename):
  ```bash
  base=$(basename "$ROSTER")                      # sssf.hello.config.yaml
  name=${base#sssf.}; name=${name%.config.yaml}   # -> hello
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]\+/-/g' -e 's/^-//' -e 's/-$//')
  # fallback for names that strip to nothing (e.g. sssf.config.yaml): sanitize the full basename
  [ -n "$name" ] || name=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//')
  SID="orch-$name"                                # orch-hello
  ```
  (The `tr`/`sed` sanitize mirrors the tag derivation in `create.just` — same idiom, same character class.)
- Banner line: `[orch] resume:   re-run this same command — pi --session-id orch-hello creates-or-continues`
- Launch: `pi --session-id "$SID" "<kickoff prompt>"` (interactive, like today; NOT `-p`).

**Kickoff prompt (both harnesses, THIN — the cookbook holds the detail):**
```
Read and execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md, then the cookbook .claude/skills/sssf-sandbox-orchestrator/cookbooks/focus_on_app.md. SSSF_CONFIG is already exported and names your roster: <abs path>. Every roster-consuming just command uses it — do not set or override it.
```
(Interpolate `$ROSTER`.)

**cc resume discoverability:** implement as a comment block directly above the `cc` recipe
explaining `claude --dangerously-skip-permissions --continue` from the repo root continues the most
recent orchestrator conversation (and that it is session-local, unlike pi's deterministic id), plus
the banner line above. A paired recipe is explicitly allowed by the spec but the comment + banner +
README line is sufficient and keeps the recipe surface at two.

### 2. `.claude/skills/sssf-sandbox-orchestrator/cookbooks/focus_on_app.md` — NEW

The instructive cookbook the kickoff points at. Sections:
- **The working rule**: `SSSF_CONFIG` is already exported to this session by `just sbx orch cc|pi
  <roster>` — every roster-consuming just command (`mount`, `lifecycle create/fill/teardown`,
  `manage doctor/harvest`, `adw …`, `obs …`) just works. Never set, unset, or override it; never
  pass a different roster.
- **Orient on the app**: read the roster's `app:` block (`repo`/`ref`/`path`/`manifest`) — it is
  the per-app input; read the app's `sssf.app.yaml` (the manifest): if `app.repo` is set, either
  clone it locally (scratch, e.g. under `/tmp` — never into this repo) to read it, or read it after
  mount inside the VM at `~/app/<path>` via `just sbx run cmd`; vendored mode → the manifest is at
  `<app.path>/sssf.app.yaml` in this repo.
- **Mount if no sandbox is up**: `just sbx manage doctor` first (preflight; the arming check
  explains itself — UNARMED warning names the fix), then `just sbx mount <run-id>`; report the run id.
- **Develop via the execute lane**: `just sbx lifecycle execute <run-id> "<prompt>"` is the factory;
  `just sbx run agent <run-id> "<prompt>"` is steering (one pi turn, resumable); never `just adw` on
  the host (hard rule 2).
- **Observe, harvest, teardown**: `run cmd` / `obs` for watching; `manage harvest` freely;
  teardown is the human's call (hard rule 1).
- Cross-link `cookbooks/mount_one.md`, `execute_work.md`, `observe_and_report.md` instead of
  re-teaching them.

### 3. Congruence pass

- `.claude/skills/sssf-sandbox-orchestrator/SKILL.md`:
  - Drive-surface tree line 136: `└── orch   boot a host-side orchestrator: `orch cc`, `orch pi``
    → mention the mandatory roster arg: ``orch cc <roster>`, `orch pi <roster>`` (focus on that
    roster's app; exports SSSF_CONFIG).
  - Cookbook table: add a row — "Orient on the app this roster names" / "booted via `just sbx orch
    cc|pi <roster>`; first move in any orchestrator session" → `cookbooks/focus_on_app.md`.
  - The `SSSF_CONFIG is required` section: add one line noting `just sbx orch cc|pi <roster>`
    exports it for the whole orchestrator session (the param wins over `.env`).
- `.claude/skills/sssf-sandbox-orchestrator/cookbooks/just_command_model.md`: the namespace table
  (line ~14) enumerates recipes without the orch pair — add ``just sbx orch cc <roster>`, `just sbx
  orch pi <roster>`` to the list. No other cookbook references orch booting (verified by grep:
  `debug_a_failed_gate.md` and `fan_out_n.md` use the word "orchestrator" generically — leave them).
- `just/sandbox/orch/mod.just` header (covered in step 1).
- `just/sandbox/mod.just` line 21 comment `just sbx orch   boot a host-side orchestrator agent` —
  fine as-is (no usage shape stated); leave unless the builder sees drift.

### 4. `README.md` — Orchestrator subsection

Add a short `### Orchestrator` subsection inside/just after `## Use` (before or after the lane
mental model — builder picks the tighter fit). Content:
- Boot: `just sbx orch cc adws/adw_sssf_config/sssf.hello.config.yaml` (Claude Code) or `just sbx
  orch pi …` — the roster argument is mandatory; the boot validates the file, exports `SSSF_CONFIG`
  (overriding `.env`), and prints the roster's `app.repo`/`app.path` — "focus" means the whole
  session's roster-consuming commands target that roster's app.
- Resume: pi — re-run the same command (deterministic `--session-id orch-<roster-name>`,
  creates-or-continues); cc — `claude --dangerously-skip-permissions --continue` from the repo root.
- Commands must be character-identical to what the recipes accept/print (reviewer gate e).

## Verification (all for real, on the host)

a. `just sbx orch` (bare) exits 0 and lists `cc`, `pi`, `default` with the new doc comments;
   `just --list sbx::orch` shows the `SSSF_CONFIG_FILE` positional in usage.
b. `just sbx orch cc` with no arg → just's usage error, non-zero exit (assert via exit code, not
   output words). `just sbx orch pi /nonexistent.yaml` → stderr contains `[orch] roster file
   '/nonexistent.yaml' not found`, exit 1, nothing launched (returns immediately — no interactive
   session starts).
c. Resume mechanism, live: derive the session id with the recipe's exact shell logic against
   `adws/adw_sssf_config/sssf.hello.config.yaml` (expect `orch-hello`), then:
   ```bash
   pi -p --session-id orch-hello "This orchestrator's roster is adws/adw_sssf_config/sssf.hello.config.yaml and the app it builds is hello-server. Remember the app."
   pi -p --session-id orch-hello "what app does this orchestrator build? answer from memory"
   ```
   The second reply must name hello-server from the first turn's context (proves
   create-or-continue). Both calls are `-p` one-shots — no interactive session. Afterwards confirm
   `git status --short` shows no stray session files in the repo (pi stores sessions under `~/.pi`).
d. Kickoff prompt inspectable without launching: `just --show sbx::orch::cc` and `just --show
   sbx::orch::pi` print the recipe source including the full prompt string. Do NOT launch
   interactive claude/pi from the build.
e. Reviewer re-checks: every command in the new cookbook and README subsection against the actual
   recipes (names, arg order, the resume commands).

## Notes / gotchas

- just makes positionals mandatory by default — `cc SSSF_CONFIG_FILE:` is all it takes for (b)'s
  usage error.
- `set dotenv-load` stays: `.env` still supplies provider keys; the exported `SSSF_CONFIG` overrides
  `.env`'s because export happens after dotenv-load, in the recipe body.
- Keep the launch lines LAST in each recipe body so nothing after them is skipped.
- The two recipe bodies duplicate the validation/parse/banner logic (cc/pi differ only in session
  id + launch) — add a "keep in sync" comment, matching how `roster_keys.sh`/gate E document their
  second copy.
- Do not touch `.sandbox/`, `adws/adw_data/`, or any run artifacts. Commit is owned by the chain's
  commit phase.
