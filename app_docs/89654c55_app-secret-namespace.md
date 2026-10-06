# Generic `APP_*` app-secret namespace

The kernel now has a declared channel for app-side credentials: any host `.env`
variable whose name starts with `APP_` ships into the VM's `app/.env` over the
same stdin-only, 0600, never-echoed pipe as the LLM keys, and
`sandbox_mount/guest/provision.sh` sources that file before each manifest
`install:`/`build:` command — so those commands see the values as environment
variables with no hand-sourcing. A manifest can now provision dependencies that
need credentials (motivating example: install tailscale, then
`tailscale up --auth-key=$APP_TAILSCALE_AUTHKEY` to join a tailnet).

The existing security invariants are unchanged and re-asserted in comments:
stdin-only pipe, `umask 077` + `chmod 600` on the VM, the fill proof line prints
names only, and the host-only overrides (`SSSF_CONFIG`, `PI_MODELS_PATH`,
`PI_PATH`, `ENGINEER_NAME`) still never cross — they don't match the explicit
LLM allowlist and they don't start with `APP_`.

## Files

- `just/sandbox/lifecycle/fill.just` — the `CRED_ENV_VARS` step keeps its
  explicit LLM-key list (including `APP_REPO_GIT_TOKEN`) exactly as-is, then
  adds a second pass that ships every host env var whose name starts with
  `APP_`. The new pass uses `compgen -e APP_`, not `${!APP_@}`: prefix
  expansion of shell variables would sweep up the recipe's own locals
  (`APP_REPO` / `APP_REF` / `APP_PATH`, assigned earlier in the same recipe)
  into `app/.env`. `compgen -e` lists only EXPORTED names, which is exactly
  the host `.env` dotenv-load put in this process — never the recipe's locals.
  Anything already shipped by the explicit loop is skipped (the
  `APP_REPO_GIT_TOKEN` entry in the explicit list is now subsumed by the
  `APP_` rule — same result, kept visible in the documentation list).
  Empty/unset values don't ship, matching the explicit loop. The file-top
  block ("ONE shape of secret crosses the wire") and the step's header
  comment are updated to describe the three kinds (LLM keys, optional
  `APP_REPO_GIT_TOKEN`, the `APP_*` namespace).
- `sandbox_mount/guest/provision.sh` — the app step (5/9) sources the
  factory-root `.env` (which on the VM is `$HOME/app/.env` ==
  `$REPO_ROOT/.env`, since the factory clone is the home directory) before
  each manifest command. The new code lives inside `run_app_stage`'s subshell
  for both `INSTALL` and `BUILD`, and inside the `package.json` fallback's
  subshell — `set -a; . "$REPO_ROOT/.env"; set +a` guarded by
  `[[ -f "$REPO_ROOT/.env" ]]` so an absent file is normal (nothing shipped),
  never an error. This mirrors the existing summary step 9/9 idiom. Everything
  else is identical: subshell from the app dir, `STEP` naming for the ERR
  trap, the trap itself, the `say` lines, the runtime gate, the absent-manifest
  skip logic.
- `README.md` — a new "App credentials: the `APP_*` namespace" subsection in
  the arming/manifest area, after the field-table examples. Documents the
  channel, gives a tailscale example, notes that auth keys should be reusable
  and ephemeral-tagged (so disposable VMs don't accumulate in the tailnet),
  and reminds that idempotent guards like `command -v tailscale` keep re-mounts
  fast when the first mount after adding a heavy install downloads over a
  slow link.
- `specs/89654c55_app-secret-namespace.md` — the design spec: goal, context,
  per-file changes, and the four-property verification procedure (canary
  ships, manifest env sees it, no regression, host-only overrides still
  blocked).

## How to use it

Put the credential in the host `.env` with an `APP_` prefix:

```sh
APP_TAILSCALE_AUTHKEY=tskey-...
```

Declare the install in `sssf.app.yaml` and read it from the environment:

```yaml
runtime: none
install:
  - command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
  - sudo tailscale up --auth-key="$APP_TAILSCALE_AUTHKEY" --ephemeral
```

On the next mount, `fill` ships the value into `~/app/.env` on the VM (0600,
proven by `stat -c "%a" ~/app/.env` → `600`) and `provision.sh` exports it
before `bash -c "$cmd"` runs the install. The fill proof line
`==> fill: app/.env (mode/size: ...) — env keys: ...` lists `APP_TAILSCALE_AUTHKEY`
by name only — values are never echoed.

## How to verify it

The four properties, against a fresh VM, using the hello roster
(`SSSF_CONFIG=adws/adw_sssf_config/sssf.hello.config.yaml`) and a marked
test value `APP_CANARY=canary-value-shape` (NOT a real secret — printing is
acceptable since it's marked):

- **(a) Canary ships.** `ssh <vm> 'grep -c "^APP_CANARY=" ~/app/.env'` → `1`.
  One file, since `~/app/.env` IS the factory-root `.env` on the VM.
  `stat -c "%a" ~/app/.env` → `600`. The fill proof line names `APP_CANARY`.
- **(b) Manifest-env proof.** Overwrite the manifest ON THE VM ONLY (the hello
  roster is target mode and `hello-server`'s real manifest lives in that repo —
  a scratch manifest is disposable, never committed to any host repo):
  `runtime: bun`, `install: [test -n "$APP_CANARY" && touch .app_env_sourced]`.
  Re-run `ssh <vm> 'PROVISION_REPO_ROOT=$HOME/app bash -s' <
  sandbox_mount/guest/provision.sh` (idempotent). Assert
  `ssh <vm> 'test -f ~/app/target/.app_env_sourced && echo MARKER_OK'` →
  `MARKER_OK`. Restore with
  `ssh <vm> 'git -C ~/app/target checkout -- sssf.app.yaml; rm -f
  ~/app/target/.app_env_sourced'`.
- **(c) Regression.** Hello-server mounts and serves as before (no `APP_*`
  required). Setup gates B/E green prove pi still sees the LLM keys. Spot
  check: `grep -c "^DEEPSEEK_API_KEY=" ~/app/.env` → `1` (hello roster's
  default provider).
- **(d) Host-only overrides stay home.**
  `ssh <vm> 'grep -cE "^(SSSF_CONFIG|PI_MODELS_PATH|PI_PATH|ENGINEER_NAME)="
  ~/app/.env' || true` → `0`.

Cleanup: remove the `APP_CANARY` line from host `.env`; teardown the canary
run once assertions are recorded.

## Out of scope

- Actually installing tailscale in any fixture.
- The factory repo.
- Parked items.
- A `.env.sample` line for `APP_TAILSCALE_AUTHKEY` — the prompt does not ask
  for it; leaving `.env.sample` unchanged.
