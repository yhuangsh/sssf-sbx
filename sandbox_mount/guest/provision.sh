#!/usr/bin/env bash
# provision.sh — turn a freshly cloned repo on a blank exeuntu VM into a
# running software factory. Two supported invocation forms, both INSIDE the
# sandbox:
#
#   ssh <vm> 'bash app/sandbox_mount/guest/provision.sh'               # in-clone
#   ssh <vm> 'PROVISION_REPO_ROOT="$HOME/app" bash -s' < provision.sh  # host-piped
#
# The host-piped form exists because the VM clones a THIRD-PARTY read-only repo:
# a provisioner fix committed locally could never reach the box through the clone
# (this machine has no push access to it), and gate A forbids writing the script
# into the tracked app/ tree. setup.just therefore streams this file from the HOST
# checkout over ssh stdin; the provisioner that runs is whatever the host working
# tree has, which is intentional. PROVISION_REPO_ROOT tells the piped script where
# the cloned repo lives, since BASH_SOURCE is meaningless under `bash -s`.
#
# Idempotent by construction: every install is skip-if-present and the tracer's
# DDL is CREATE TABLE IF NOT EXISTS. Re-running is cheap and safe.
#
# NEVER add apt to this file. Measured from the dal region: ~148 kB/s, ~35s per
# package. bun and just come from their own CDNs in ~1s combined.
set -euo pipefail

STEP="startup"
# shellcheck disable=SC2154   # rc is assigned by the trap body itself
trap 'rc=$?; echo "" >&2; echo "[provision] FAILED during: ${STEP} (line ${LINENO}, exit ${rc})" >&2; exit "$rc"' ERR

step() { STEP="$1"; echo ""; echo "── $1 ──────────────────────────────────"; }
say()  { echo "   $*"; }

# ── 1. locate the repo ───────────────────────────────────────────────────────
# REPO_ROOT comes from PROVISION_REPO_ROOT when set (setup.just pipes this script
# to the VM over ssh stdin, where BASH_SOURCE is meaningless), else from this
# script's own path, never hardcoded to /home/exedev/app.
if [[ -n "${PROVISION_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$PROVISION_REPO_ROOT"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
cd "$REPO_ROOT"

step "1/9 repo root"
say "$REPO_ROOT"
say "commit $(git rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"

# ── 2. bun ───────────────────────────────────────────────────────────────────
step "2/9 bun"
if command -v bun >/dev/null 2>&1; then
  say "already installed: $(bun --version)"
else
  curl -fsSL https://bun.sh/install | bash
  say "installed"
fi
# The installer only edits shell rc files, which this non-interactive shell never
# reads — put it on PATH by hand for the rest of the run.
if [[ -d "$HOME/.bun/bin" ]]; then
  export PATH="$HOME/.bun/bin:$PATH"
fi
# ...and symlink it where every FUTURE ssh session will find it. Each `ssh vm cmd`
# is a fresh non-interactive shell that reads no rc file, so a PATH export here
# dies with this script. OBSERVE hit exactly that: it started the app with nohup
# and got `bun: No such file or directory` while provision had just used bun
# successfully. just avoids this by installing to /usr/local/bin already.
if [[ -x "$HOME/.bun/bin/bun" ]] && [[ ! -e /usr/local/bin/bun ]]; then
  sudo ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
  sudo ln -sf "$HOME/.bun/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true
  say "linked into /usr/local/bin for non-interactive ssh"
fi
command -v bun >/dev/null 2>&1 || { echo "[provision] bun not on PATH after install" >&2; exit 1; }

# ── 3. just ──────────────────────────────────────────────────────────────────
# Never apt. Note for anything that calls just in here later:
#   just --shell bash --shell-arg -c
# the root justfile sets `zsh -ic` and zsh is not in the image.
step "3/9 just"
if command -v just >/dev/null 2>&1; then
  say "already installed: $(just --version)"
else
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | sudo bash -s -- --to /usr/local/bin
  say "installed"
fi
command -v just >/dev/null 2>&1 || { echo "[provision] just not on PATH after install" >&2; exit 1; }

# ── 4. pi agent (latest) ─────────────────────────────────────────────────────
# No models.json, no mirrored registry: every roster provider is a pi BUILT-IN,
# keyed by the env vars FILL ships into app/.env. What the sandbox needs from
# this step is the binary itself, current — the exeuntu image bakes an OLD native
# pi and ships NO node/npm (and that baked binary refuses to self-update: `pi
# update` bails at /$bunfs/root/pi). So bootstrap a standalone Node from
# nodejs.org — never apt — then install the npm `latest` through the normal
# npm-global path. Node/npm are symlinked into /usr/local/bin because the
# npm-installed pi is a `#!/usr/bin/env node` script, and every future
# `ssh vm cmd` is a fresh non-interactive shell that reads no rc file.
step "4/9 pi agent (latest)"
NODE_DIR="$HOME/.local/node"
if [[ -x "$NODE_DIR/bin/node" ]]; then
  export PATH="$NODE_DIR/bin:$PATH"   # re-run fast path: node already bootstrapped
fi
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  NODE_VER="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ \
    | sed -n 's/.*node-v\([0-9.]*\)-linux-x64\.tar\.xz.*/\1/p' | sort -u | tail -n 1)"
  [[ -n "$NODE_VER" ]] || { echo "[provision] could not resolve a Node 22 release from nodejs.org" >&2; exit 1; }
  say "bootstrapping standalone Node v${NODE_VER} into ${NODE_DIR} (no apt)"
  mkdir -p "$NODE_DIR"
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/node-v${NODE_VER}-linux-x64.tar.xz" \
    | tar -xJ --strip-components=1 -C "$NODE_DIR"
  export PATH="$NODE_DIR/bin:$PATH"
fi
for b in node npm npx; do
  [[ -x "$NODE_DIR/bin/$b" ]] || continue
  sudo ln -sf "$NODE_DIR/bin/$b" "/usr/local/bin/$b"
done
command -v npm >/dev/null 2>&1 || { echo "[provision] npm missing after Node bootstrap" >&2; exit 1; }
PI_PKG="@earendil-works/pi-coding-agent"
# Resolve the `latest` dist-tag ONCE and install that exact version below: a
# second `@latest` resolution could land a version the compare above rejected.
LATEST="$(npm view "$PI_PKG" version)"
CUR="$(pi --version 2>/dev/null || echo none)"
if [[ "$CUR" == "$LATEST" ]]; then
  say "pi already at latest ($CUR)"
else
  say "pi $CUR -> $LATEST"
  npm install -g "$PI_PKG@$LATEST" || sudo npm install -g "$PI_PKG@$LATEST"
fi
# Global npm installs into its own prefix and the image bakes a native pi at
# /usr/local/bin/pi. Relink that path at the fresh npm-global binary ON EVERY
# run: /usr/local/bin precedes /usr/bin and the npm prefixes in every
# non-interactive ssh shell, so a stale baked pi can never shadow the install.
# Unconditional (not "only when command -v pi differs") because this shell has
# $NODE_DIR/bin prepended and would otherwise see the right binary while future
# ssh shells still see the baked one.
NPREFIX="$(npm prefix -g 2>/dev/null || true)"
if [[ -n "$NPREFIX" && -x "$NPREFIX/bin/pi" ]]; then
  sudo ln -sf "$NPREFIX/bin/pi" /usr/local/bin/pi
  hash -r
  say "linked $NPREFIX/bin/pi -> /usr/local/bin/pi for non-interactive ssh"
fi
command -v pi >/dev/null 2>&1 || { echo "[provision] pi not on PATH after install" >&2; exit 1; }
# Hard assertion, not a passive report: a shadowed binary or a registry outage
# must FAIL the mount. Plain exit 1 so the sentinel below is never touched.
[[ "$(pi --version 2>/dev/null)" == "$LATEST" ]] || {
  echo "[provision] pi is at $(pi --version 2>/dev/null || echo missing), registry latest is $LATEST" >&2
  exit 1
}
say "pi $(pi --version) (registry latest)"

# ── 5. app (generic, manifest-driven) ────────────────────────────────────────
# The app is whatever the shipped roster's `app:` block names, and its needs are
# declared in its own sssf.app.yaml — never hardcoded here. ONE parser: a uv-run
# PEP-723 probe (pyyaml already a tracer dependency) resolves app.path and
# app.manifest from /home/exedev/sssf_config.yaml into shell-quoted assignments.
# A runtime we cannot provide fails fast BY NAME; it is NEVER an excuse for apt.
step "5/9 app"
APP_PROBE="$(mktemp -t sssf_app_probe.XXXXXX.py)"
cat > "$APP_PROBE" <<'PY'
# /// script
# dependencies = ["pyyaml"]
# ///
"""Resolve app.path/app.manifest + the manifest's install/build into shell vars."""

import shlex
import sys
from pathlib import Path

import yaml

repo_root = Path(sys.argv[1])
try:
    cfg = yaml.safe_load(Path("/home/exedev/sssf_config.yaml").read_text()) or {}
except FileNotFoundError:
    cfg = {}
app = cfg.get("app") or {}
path = app.get("path") or "apps/inkwell"
manifest = app.get("manifest") or "sssf.app.yaml"
manifest_path = repo_root / path / manifest
present = manifest_path.is_file()
data = (yaml.safe_load(manifest_path.read_text()) or {}) if present else {}
install = [str(c) for c in (data.get("install") or [])]
build = [str(c) for c in (data.get("build") or [])]


def emit(key, value):
    print(f"{key}={shlex.quote(str(value))}")


emit("APP_PATH", path)
emit("APP_MANIFEST", manifest)
emit("APP_MANIFEST_PRESENT", 1 if present else 0)
emit("APP_RUNTIME", data.get("runtime") or "")
emit("APP_INSTALL_COUNT", len(install))
for i, cmd in enumerate(install):
    emit(f"APP_INSTALL_{i}", cmd)
emit("APP_BUILD_COUNT", len(build))
for i, cmd in enumerate(build):
    emit(f"APP_BUILD_{i}", cmd)
PY
# The probe's own uv resolve goes to stderr; stdout is exactly the assignments.
# Capture first (so a failing probe fails under set -e) and eval the quoted lines.
APP_ENV="$(uv run "$APP_PROBE" "$REPO_ROOT")"
rm -f "$APP_PROBE"
eval "$APP_ENV"

APP_DIR="$REPO_ROOT/$APP_PATH"
# Defensive backstop, now unreachable in normal flow: mount's HOST-SIDE arming
# preflight (just/sandbox/mount.just) fails in seconds on a missing vendored
# app.path long before any VM exists. This exit only fires for out-of-band
# invocation (someone piping provision.sh to a VM directly, or a hand-shipped
# roster that diverged from the host's).
if [[ ! -d "$APP_DIR" ]]; then
  echo "[provision] app.path '$APP_PATH' does not exist under $REPO_ROOT" >&2
  exit 1
fi
say "app      $APP_PATH"
if [[ "$APP_MANIFEST_PRESENT" == 1 ]]; then
  say "manifest $APP_MANIFEST"
else
  say "manifest $APP_MANIFEST absent — package.json fallback"
fi

# Runtime: only toolchains the image / steps 2-4 already provide. A declared
# runtime we cannot honour is a named failure, never an apt install.
if [[ -n "${APP_RUNTIME:-}" && "$APP_RUNTIME" != "none" ]]; then
  case "$APP_RUNTIME" in
    bun|node|uv) ;;
    *) echo "[provision] manifest declares runtime '$APP_RUNTIME' — not provided by this image (no apt fallback)" >&2; exit 1 ;;
  esac
  if ! command -v "$APP_RUNTIME" >/dev/null 2>&1; then
    echo "[provision] manifest declares runtime '$APP_RUNTIME' but it is not on PATH" >&2
    exit 1
  fi
  say "runtime  $APP_RUNTIME"
fi

# Each declared command runs in a subshell from the app dir; STEP names the stage
# so the ERR trap reports it. Absent key = skip with a say line, never a failure.
run_app_stage() {
  local kind="$1" count="$2" i var cmd
  for ((i = 0; i < count; i++)); do
    var="APP_${kind}_${i}"
    cmd="${!var}"
    say "${kind,,}: $cmd"
    STEP="app ${kind,,}: ${cmd}"
    (
      cd "$APP_DIR"
      # FILL ships LLM + APP_* credentials to the factory-root .env, which on
      # this VM is $HOME/app/.env == $REPO_ROOT/.env. Source it (exported) so the
      # manifest's install:/build: commands see APP_* (and the LLM keys) as
      # environment variables without hand-sourcing. Mirrors summary step 9/9.
      # Absent is normal — nothing was shipped — never an error.
      if [[ -f "$REPO_ROOT/.env" ]]; then set -a; . "$REPO_ROOT/.env"; set +a; fi
      bash -c "$cmd"
    )
  done
}

if [[ "$APP_MANIFEST_PRESENT" == 1 ]]; then
  if [[ "${APP_INSTALL_COUNT:-0}" -gt 0 ]]; then
    run_app_stage INSTALL "$APP_INSTALL_COUNT"
  else
    say "install: skipped (no install: in manifest)"
  fi
  if [[ "${APP_BUILD_COUNT:-0}" -gt 0 ]]; then
    run_app_stage BUILD "$APP_BUILD_COUNT"
  else
    say "build: skipped (no build: in manifest)"
  fi
elif [[ -f "$APP_DIR/package.json" ]]; then
  say "no manifest — package.json fallback: bun install"
  STEP="app fallback: bun install"
  (
    cd "$APP_DIR"
    # Same credential channel as run_app_stage: manifest-equivalent fallback
    # installs see APP_*/LLM vars too.
    if [[ -f "$REPO_ROOT/.env" ]]; then set -a; . "$REPO_ROOT/.env"; set +a; fi
    bun install
  )
else
  say "skipped $APP_PATH (no manifest, no package.json)"
fi

# ── 6. build the visualizer UI (factory runtime) ─────────────────────────────
# The visualizer is factory machinery, not app payload, so its install lives
# here rather than in the app step. Without dist/ the server still boots but only
# answers the JSON API — the page itself 404s. `bunx vite build` rather than
# `bun run build`, which also runs vue-tsc; type errors must not be able to fail
# a mount.
step "6/9 visualizer"
VIZ=".claude/skills/sssf/apps/visualizer"
if [[ -d "$VIZ" ]]; then
  if [[ -f "$VIZ/package.json" ]]; then
    ( cd "$VIZ" && bun install )
    say "installed ${VIZ}"
  else
    say "skipped ${VIZ} (no package.json)"
  fi
  ( cd "$VIZ" && bunx vite build )
  say "dist/ built"
else
  say "skipped (visualizer absent)"
fi

# ── 7. trace db ──────────────────────────────────────────────────────────────
# VERIFIED: the visualizer process EXITS when sssf.db is missing, and `just
# mount` ends at observe BEFORE any ADW has run — so a fresh sandbox would start
# a UI that dies instantly. Tracer's DDL is all CREATE TABLE IF NOT EXISTS, so
# calling it here is idempotent and stays correct if the schema moves.
step "7/9 trace db"
INIT_DB="$(mktemp -t sssf_init_db.XXXXXX.py)"
cat > "$INIT_DB" <<'PY'
# /// script
# dependencies = ["pydantic", "python-dotenv", "pyyaml", "rich"]
# ///
"""Create sssf.db and its schema without running an ADW."""

import sys
from pathlib import Path

sys.path.insert(0, "adws")          # the import root `uv run adws/adw_*.py` gets

from adw_modules.agents import load_config
from adw_modules.tracer import Tracer

cfg = load_config()
db = Path(cfg.observability.db)
# Tracer only mkdirs the events file's PARENT, so passing the sessions dir
# itself creates that dir and leaves no stray session behind.
tracer = Tracer(db, Path(cfg.defaults.data_dir) / "sessions" / "events.jsonl")
tables = tracer.conn.execute(
    "SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
print(f"   {db} — {tables} tables")
PY
uv run "$INIT_DB"
rm -f "$INIT_DB"

# ── 8. warm the uv cache ─────────────────────────────────────────────────────
# The PEP-723 resolve is ~3s cold and near zero after. Pay it here rather than
# inside the first agent run, where it looks like the agent hanging.
step "8/9 warm uv"
if uv run adws/adw_prompt.py --help >/dev/null 2>&1; then
  say "uv cache warm"
else
  echo "[provision] uv run adws/adw_prompt.py --help failed" >&2
  uv run adws/adw_prompt.py --help >&2 || true
  exit 1
fi

# ── summary ────────────────────────────────────────────────────────────────
step "9/9 summary"
say "repo    $REPO_ROOT @ $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
say "bun     $(bun --version)"
say "just    $(just --version)"
say "uv      $(uv --version)"
say "pi      $(pi --version 2>/dev/null || echo 'not installed')"
say "python  $(python3 --version)"
# Keys live in app/.env (FILL-shipped); source it in a subshell for an honest
# count without leaving the vars exported, and never fail the run on it —
# `pi --list-models` prints "No models available" and exits 0 with no creds.
# `|| true` inside the pipeline, not after it: pipefail would otherwise hand a
# failure of an absent/unhappy pi to the ERR trap and skip the sentinel below.
MODEL_LINES=$(
  cd "$REPO_ROOT"
  if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
  { pi --list-models 2>/dev/null || true; } | grep -c . || true
)
say "models  ${MODEL_LINES} lines from pi --list-models (credentials from app/.env)"
echo ""
echo "[provision] READY"

# The caller polls for this file — there is no other reliable completion signal.
# It must stay the last line: anything after it can fail after the host has
# already been told the sandbox is ready.
touch /tmp/PROVISION_READY
