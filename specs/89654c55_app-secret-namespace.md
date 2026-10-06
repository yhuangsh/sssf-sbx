# Generic `APP_*` app-secret namespace for the sandbox kernel

## Goal

Give the kernel a generic app-secret namespace so a manifest's `install:` /
`build:` commands can provision dependencies that need credentials (motivating
example: tailscale — install the binary, then
`tailscale up --auth-key=$APP_TAILSCALE_AUTHKEY` to join a tailnet).

Three files change: `just/sandbox/lifecycle/fill.just`,
`sandbox_mount/guest/provision.sh`, `README.md`. Then a fresh-VM verification
of four properties (canary ships, manifest env sees it, no regression, host-only
overrides still blocked).

## Context that matters

- Root `justfile` has `set dotenv-load`, so host `.env` vars are already in the
  recipe environment of `fill` — a bash loop over `${!APP_@}` inside the recipe
  sees them with no extra plumbing.
- `fill.just` already ships an explicit allowlist (`CRED_ENV_VARS`) of LLM keys
  **plus `APP_REPO_GIT_TOKEN`** into `~/app/.env` on the VM (stdin pipe,
  `umask 077`, `chmod 600`, proof line prints NAMES only).
- On the VM, `REPO_ROOT` in `provision.sh` is `$HOME/app` (the factory clone),
  so the FILL-shipped credential file **is** `$REPO_ROOT/.env`. The provision
  summary step (9/9) already sources it with `set -a; . ./.env; set +a` —
  reuse that exact idiom for the app stages.
- The hello roster (`adws/adw_sssf_config/sssf.hello.config.yaml`) is target
  mode: the app is a clone of `hello-server` at `~/app/target`, and its real
  manifest lives in that repo — we cannot commit a scratch manifest there. The
  manifest-env proof (b) therefore overwrites the manifest **on the VM only**
  (disposable, torn down after), never in a repo.
- `provision.sh`'s app step runs each manifest command as
  `( cd "$APP_DIR" && bash -c "$cmd" )` inside `run_app_stage`, with
  `STEP="app ${kind,,}: ${cmd}"` for the ERR trap, plus a package.json fallback
  `( cd "$APP_DIR" && bun install )`.

## Changes

### 1. `just/sandbox/lifecycle/fill.just` — widen the ship rule

In the CRED_ENV_VARS step ("── ship credentials BEFORE the target clone ──"):

- **Keep the explicit `CRED_ENV_VARS` list exactly as-is**, including
  `APP_REPO_GIT_TOKEN` (it starts with `APP_`, so the new rule subsumes it —
  the explicit entry keeps it working identically and keeps the token visible
  in the list's documentation value).
- **Add, after the existing loop**, a second pass over every host-environment
  variable whose name starts with `APP_`:

  ```bash
  # APP_* namespace: the app's declared secret channel. Every host-.env var
  # named APP_* ships alongside the LLM keys — the manifest's install:/build:
  # commands see these as environment variables (provision.sh sources the
  # landed file). APP_REPO_GIT_TOKEN is already in the explicit list above;
  # skip anything already shipped.
  for v in "${!APP_@}"; do
      case " ${SHIPPED[*]} " in *" $v "*) continue ;; esac
      val="${!v:-}"
      if [ -n "$val" ]; then
          ENV_CONTENT+="$v="$'\n'... # same shape as the explicit loop: "$v=$val"$'\n'
          SHIPPED+=("$v")
      fi
  done
  ```

  (`${!APP_@}` expands to all set variable names with that prefix; under
  `set -u` this is safe — it expands to nothing when no such var exists. The
  empty-value guard matches the explicit loop: unset-or-empty does not ship.
  Single-line values only, same as the existing discipline.)
- **Re-assert the unchanged security invariants in the comments** around this
  step: stdin-only (the `printf | ssh 'umask 077 && cat > ... && chmod 600'`
  pipe), 0600 on the VM, never echoed (proof line prints NAMES only), and the
  host-only overrides `SSSF_CONFIG`, `PI_MODELS_PATH`, `PI_PATH`,
  `ENGINEER_NAME` still never cross (they do not match the allowlist or the
  `APP_` prefix — state this explicitly).
- **Update the step's header comment** (both the short "THE credential path"
  block above `CRED_ENV_VARS` and the file-top "ONE shape of secret crosses
  the wire" block) to describe the widened rule: two explicit kinds (LLM
  provider keys, `APP_REPO_GIT_TOKEN`) **plus the `APP_*` namespace** — the
  app's declared secret channel, visible as environment variables to the
  manifest's `install:`/`build:` commands.

### 2. `sandbox_mount/guest/provision.sh` — source the landed .env in app stages

In step "5/9 app":

- In `run_app_stage`, change the subshell from
  `( cd "$APP_DIR" && bash -c "$cmd" )` to source the factory-root `.env`
  first, **only if present**:

  ```bash
  (
    cd "$APP_DIR"
    # FILL ships LLM + APP_* credentials to the factory-root .env (which is
    # $HOME/app/.env on this VM). Source it so manifest install:/build:
    # commands see them as environment variables without hand-sourcing.
    if [[ -f "$REPO_ROOT/.env" ]]; then set -a; . "$REPO_ROOT/.env"; set +a; fi
    bash -c "$cmd"
  )
  ```

- Apply the same sourcing to the package.json fallback:
  `( cd "$APP_DIR" && bun install )` gets the same `set -a; . ...; set +a`
  guard before `bun install`.
- Keep everything else identical: subshell from the app dir, `STEP` naming
  (`STEP="app ${kind,,}: ${cmd}"` stays BEFORE the subshell so the ERR trap
  reports the failing command), the ERR trap itself, the `say` lines, the
  runtime gate, and the absent-manifest skip logic.
- A short comment noting this mirrors the summary step 9/9 idiom and that the
  file is absent (not an error) when no credentials were shipped.

### 3. `README.md` — document the channel

In the `## Arming for any language` section (after the manifest field table,
near the manifest examples), add a short paragraph:

- Extra credentials your app's provisioning needs go in the host `.env` as
  `APP_*` variables.
- They ship into the sandbox by the same stdin/0600 path as the LLM keys and
  land in `app/.env`; `provision.sh` sources that file before each manifest
  command, so the manifest's `install:`/`build:` commands see them as
  environment variables.
- Host-only overrides (`SSSF_CONFIG`, `PI_*`, `ENGINEER_NAME`) never cross.
- Example: `.env` line `APP_TAILSCALE_AUTHKEY=tskey-...` plus a manifest
  install example:

  ```yaml
  install:
    - command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
    - sudo tailscale up --auth-key="$APP_TAILSCALE_AUTHKEY" --ephemeral
  ```

- Notes: auth keys should be reusable and ephemeral-tagged so disposable VMs do
  not accumulate in the tailnet; the first mount after adding a heavy install
  downloads over a slow link — idempotent guards like `command -v tailscale`
  keep re-mounts fast.

## Verification (for real, on a fresh VM)

Setup: add `APP_CANARY=canary-value-shape` to the host `.env` (a marked test
value, NOT a real secret). Use the hello roster
(`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`) and a fresh run id,
e.g. `just sbx mount canary-1`.

**(a) Canary ships.**
- `ssh <vm>.exe.xyz 'grep -c "^APP_CANARY=" ~/app/.env'` → `1`.
- `ssh <vm>.exe.xyz 'grep "^APP_CANARY=" ~/app/.env'` → prints
  `APP_CANARY=canary-value-shape` (printing is acceptable — marked test value).
  This single file is both `app/.env` and the factory-root `.env` on the VM
  (`$HOME/app` is the factory clone), so one assertion covers both.
- The mount's fill output line `env keys: ...` must NAME `APP_CANARY` (name
  only).
- `ssh <vm>.exe.xyz 'stat -c "%a" ~/app/.env'` → `600`.

**(b) Manifest-env proof.**
- Overwrite the manifest **on the VM only**:
  `ssh <vm>.exe.xyz 'printf "%s\n" "runtime: bun" "install:" "  - test -n \"\$APP_CANARY\" && touch .app_env_sourced" > ~/app/target/sssf.app.yaml'`
  (mind quoting; a host-side heredoc piped to `ssh ... 'cat > ...'` is cleaner).
- Re-run the provisioner:
  `ssh <vm>.exe.xyz 'PROVISION_REPO_ROOT=$HOME/app bash -s' < sandbox_mount/guest/provision.sh`
  (idempotent — bun/just/pi fast paths; the app stage re-runs).
- Assert: `ssh <vm>.exe.xyz 'test -f ~/app/target/.app_env_sourced && echo MARKER_OK'`
  → `MARKER_OK`.
- Remove the scratch manifest before landing: restore it on the VM with
  `ssh <vm>.exe.xyz 'git -C ~/app/target checkout -- sssf.app.yaml; rm -f ~/app/target/.app_env_sourced'`.
  The scratch manifest never exists in any host repo — the tree stays clean.

**(c) Regression.**
- The mount's setup gates (A–E) are green — B/E prove pi sees the LLM keys.
- hello-server serves: `curl -sf https://<vm>.exe.xyz:4501/` (or the
  observe-reported health path) responds as before, with no `APP_*` vars
  required by it.
- `ssh <vm>.exe.xyz 'grep -c "^DEEPSEEK_API_KEY=" ~/app/.env'` → `1` (hello
  roster's default provider is deepseek).

**(d) Host-only overrides stay home.**
- `ssh <vm>.exe.xyz 'grep -cE "^(SSSF_CONFIG|PI_MODELS_PATH|PI_PATH|ENGINEER_NAME)=" ~/app/.env' || true`
  → `0`.

Cleanup: remove the `APP_CANARY` line from host `.env`, and
`just sbx lifecycle teardown canary-1` once assertions are recorded (teardown
harvests first; the scratch VM state is discarded with the VM).

## Acceptance

- (a)–(d) demonstrated on a fresh VM as above.
- Only `just/sandbox/lifecycle/fill.just`, `sandbox_mount/guest/provision.sh`,
  `README.md` changed in the repo tree.
- The chain's commit phase owns the commit; tree clean afterwards.

## Out of scope

- Actually installing tailscale in any fixture.
- The factory repo (upstream/fork changes).
- Parked items.
- `.env.sample` — the prompt does not ask for it; leave it unchanged.
