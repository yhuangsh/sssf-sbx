#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""just sbx scaffold — interactively produce a GitHub app repo this kernel can
mount OUT OF THE BOX, plus the matching roster.

Runs on the HOST, in the user's terminal. Everything it writes is DATA the
existing machinery already consumes: an `sssf.app.yaml` manifest in the app repo
(parsed by provision.sh, observe.just and quality.py) and a roster copied from
the shipped `sssf.hello.config.yaml` with only the `app:` block filled in (parsed
by mount.just and manage/mod.just with awk — hence the flat two-space keys).

Two paths, one gate:

  create-new  seed the runtime's skeleton, `gh repo create --push`
  existing    `gh repo clone`, then ADD only what is missing — never overwrite

Nothing destructive happens before the printed summary is confirmed, and the
manifest is parsed back BEFORE any push, so a scaffold bug cannot land a broken
manifest on GitHub.

Usage:
    uv run sandbox_mount/host/scaffold.py [owner/name]

The optional argument pre-fills the repo-name answer (bare Enter accepts it).
Every prompt reads exactly ONE line, so the whole flow is drivable by a piped
here-doc. pyyaml only, on purpose — this runs on the host before any toolchain
exists, like run_record.py.

`gh` is a HARD dependency of this one command: both `command -v gh` and
`gh auth status` are checked up front, with named guidance on failure.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import yaml

# sandbox_mount/host/scaffold.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[2]
ROSTERS_DIR = REPO_ROOT / "adws" / "adw_sssf_config"
TEMPLATE = ROSTERS_DIR / "sssf.hello.config.yaml"
ENV_FILE = REPO_ROOT / ".env"
PROBE_MOD_JUST = REPO_ROOT / "just" / "sandbox" / "mod.just"

# GitHub's own account/repo rules.
OWNER_RE = re.compile(r"^[A-Za-z0-9](-?[A-Za-z0-9])*$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

RUNTIMES = ("bun", "node", "uv", "none")

# One test check per runtime, matching the seeded skeleton. `none` ships a
# README-only library, so it has no test to declare.
CHECK_BY_RUNTIME: dict[str, list[str] | None] = {
    "bun": ["bun", "test"],
    "node": ["node", "--test"],
    "uv": ["uv", "run", "pytest"],
    "none": None,
}

INSTALL_BY_RUNTIME = {
    "bun": "install: [bun install]",
    "node": "install: []",
    "uv": "install: [uv sync]",
    "none": None,
}

# observe starts the app as `PORT=<serve.port> <command>`, so every skeleton
# server reads PORT from the environment and binds 0.0.0.0.
SERVE_CMD_DEFAULT = {
    "bun": "bun --hot server.ts",
    "node": "node server.js",
    "uv": "uv run python app.py",
    "none": "",
}

GITIGNORE = """node_modules/
dist/
.venv/
__pycache__/
.env
"""

# ── skeletons ────────────────────────────────────────────────────────────────
# The files each runtime's repo gets. `{{name}}` is replaced with the bare repo
# name. Kept as data so the generated repo is the ONLY thing this command
# produces — no per-app factory edits.

SKELETON: dict[str, dict[str, str]] = {
    "bun": {
        "package.json": (
            '{\n'
            '  "name": "{{name}}",\n'
            '  "version": "0.1.0",\n'
            '  "private": true,\n'
            '  "scripts": {\n'
            '    "start": "bun run server.ts"\n'
            '  }\n'
            '}\n'
        ),
        "server.ts": (
            "export function greet(name: string): string {\n"
            '  return `hello, ${name}`;\n'
            "}\n"
            "\n"
            'if (import.meta.main) {\n'
            "  const port = Number(process.env.PORT ?? 4501);\n"
            "  Bun.serve({\n"
            "    port,\n"
            '    hostname: "0.0.0.0",\n'
            '    fetch: () => new Response(greet("world") + "\\n"),\n'
            "  });\n"
            '  console.log(`listening on http://0.0.0.0:${port}`);\n'
            "}\n"
        ),
        "server.test.ts": (
            'import { describe, expect, test } from "bun:test";\n'
            'import { greet } from "./server";\n'
            "\n"
            'describe("greet", () => {\n'
            '  test("greets the world", () => {\n'
            '    expect(greet("world")).toBe("hello, world");\n'
            "  });\n"
            "});\n"
        ),
    },
    "node": {
        "package.json": (
            '{\n'
            '  "name": "{{name}}",\n'
            '  "version": "0.1.0",\n'
            '  "private": true,\n'
            '  "type": "module",\n'
            '  "scripts": {\n'
            '    "start": "node server.js",\n'
            '    "test": "node --test"\n'
            "  }\n"
            "}\n"
        ),
        "server.js": (
            'import { createServer } from "node:http";\n'
            'import { pathToFileURL } from "node:url";\n'
            "\n"
            "export function greet(name) {\n"
            '  return `hello, ${name}`;\n'
            "}\n"
            "\n"
            "export function createApp() {\n"
            "  return createServer((req, res) => {\n"
            '    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });\n'
            '    res.end(greet("world") + "\\n");\n'
            "  });\n"
            "}\n"
            "\n"
            "if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {\n"
            "  const port = Number(process.env.PORT ?? 4501);\n"
            '  createApp().listen(port, "0.0.0.0", () => {\n'
            '    console.log(`listening on http://0.0.0.0:${port}`);\n'
            "  });\n"
            "}\n"
        ),
        "server.test.js": (
            'import assert from "node:assert/strict";\n'
            'import { test } from "node:test";\n'
            'import { greet } from "./server.js";\n'
            "\n"
            'test("greet", () => {\n'
            '  assert.equal(greet("world"), "hello, world");\n'
            "});\n"
        ),
    },
    "uv": {
        "pyproject.toml": (
            "[project]\n"
            'name = "{{name}}"\n'
            'version = "0.1.0"\n'
            'description = "sssf-sbx scaffolded uv app"\n'
            'requires-python = ">=3.10"\n'
            "dependencies = []\n"
            "\n"
            "[dependency-groups]\n"
            'dev = ["pytest"]\n'
        ),
        "app.py": (
            '"""sssf-sbx scaffolded uv app: a pure greet() plus a tiny server."""\n'
            "\n"
            "import os\n"
            "from http.server import BaseHTTPRequestHandler, HTTPServer\n"
            "\n"
            "\n"
            "def greet(name: str) -> str:\n"
            '    return f"hello, {name}"\n'
            "\n"
            "\n"
            "class _Handler(BaseHTTPRequestHandler):\n"
            "    def do_GET(self):\n"
            '        body = (greet("world") + "\\n").encode()\n'
            "        self.send_response(200)\n"
            '        self.send_header("content-type", "text/plain; charset=utf-8")\n'
            '        self.send_header("content-length", str(len(body)))\n'
            "        self.end_headers()\n"
            "        self.wfile.write(body)\n"
            "\n"
            "    def log_message(self, *args):\n"
            "        pass\n"
            "\n"
            "\n"
            "def main() -> None:\n"
            "    port = int(os.environ.get(\"PORT\", \"4501\"))\n"
            '    print(f"listening on http://0.0.0.0:{port}")\n'
            '    HTTPServer(("0.0.0.0", port), _Handler).serve_forever()\n'
            "\n"
            "\n"
            'if __name__ == "__main__":\n'
            "    main()\n"
        ),
        "test_app.py": (
            "from app import greet\n"
            "\n"
            "\n"
            "def test_greet():\n"
            '    assert greet("world") == "hello, world"\n'
        ),
    },
    "none": {
        "README.md": (
            "# {{name}}\n"
            "\n"
            "Scaffolded by [sssf-sbx](https://github.com/yhuangsh/sssf-sbx) as a\n"
            "library / no-runtime repo — `observe` skips the app lane for a manifest\n"
            "with no `serve:` block.\n"
        ),
    },
}


class ScaffoldError(Exception):
    """A named, user-actionable failure. Printed as [scaffold] <msg>."""


class InputClosed(Exception):
    """stdin hit EOF mid-flow (a piped here-doc ran out of answers)."""


# ── subprocess plumbing ──────────────────────────────────────────────────────
# List argv, never shell. A failing command becomes a named [scaffold] error
# carrying the tail of its stderr, so the operator sees what gh/git said.


def run(argv: list[str], cwd: Path | None = None, echo: bool = False) -> subprocess.CompletedProcess:
    completed = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        tail = (completed.stderr or completed.stdout or "").strip().splitlines()[-8:]
        raise ScaffoldError(
            f"command failed ({completed.returncode}): {' '.join(argv)}\n"
            + "\n".join(f"  {line}" for line in tail)
        )
    if echo and completed.stdout.strip():
        print(completed.stdout.rstrip())
    return completed


def git_identity() -> list[str]:
    """Per-command -c identity only when the host has none configured.

    The app repo may be created on a machine with no global git identity; a
    commit must not fail because of that, so fall back to the gh account.
    `git config` exits 1 when a key is unset, so it must NOT go through run()'s
    check.
    """
    def configured(key: str) -> str:
        return subprocess.run(["git", "config", key], capture_output=True, text=True).stdout.strip()

    if configured("user.name") and configured("user.email"):
        return []
    return ["-c", f"user.name={GH_USER}", "-c", f"user.email={GH_USER}@users.noreply.github.com"]


def git_commit(cwd: Path, message: str) -> None:
    run(["git", *git_identity(), "commit", "-m", message], cwd=cwd)


# ── prompts ──────────────────────────────────────────────────────────────────


def ask(prompt: str, default: str = "") -> str:
    shown = f" [{default}]" if default else ""
    try:
        line = input(f"{prompt}{shown}: ").strip()
    except EOFError as error:
        raise InputClosed() from error
    return line or default


def ask_yn(prompt: str, default: bool) -> bool:
    shown = "[Y/n]" if default else "[y/N]"
    while True:
        try:
            line = input(f"{prompt} {shown}: ").strip().lower()
        except EOFError as error:
            raise InputClosed() from error
        if not line:
            return default
        if line in ("y", "yes"):
            return True
        if line in ("n", "no"):
            return False
        print("  please answer y or n")


def ask_choice(prompt: str, choices: tuple[str, ...], default: str,
               aliases: dict[str, str] | None = None) -> str:
    aliases = aliases or {}
    while True:
        line = ask(prompt, default).lower()
        line = aliases.get(line, line)
        if line in choices:
            return line
        print(f"  please answer one of: {', '.join(choices)}")


# ── manifest ─────────────────────────────────────────────────────────────────


def manifest_text(runtime: str, serve: dict | None, checks: list[str] | None) -> str:
    lines = [f"runtime: {runtime}"]
    install = INSTALL_BY_RUNTIME[runtime]
    if install:
        lines.append(install)
    if runtime == "bun":
        lines.append("build: []")
    if serve:
        lines += [
            "serve:",
            f"  command: {serve['command']}",
            f"  port: {serve['port']}",
            f"  health_path: {serve['health_path']}",
        ]
    if checks:
        lines.append("checks:")
        lines.append(f"  test: [{', '.join(checks)}]")
    return "\n".join(lines) + "\n"


def validate_manifest(text: str) -> dict:
    """Parse the manifest back BEFORE it can be pushed. A failure here is a
    scaffold bug, not user error — nothing is pushed when it raises."""
    try:
        data = yaml.safe_load(text) or {}
    except yaml.YAMLError as error:
        raise ScaffoldError(f"generated sssf.app.yaml does not parse: {error}") from None
    if not isinstance(data, dict):
        raise ScaffoldError("generated sssf.app.yaml is not a mapping")
    if data.get("runtime") not in RUNTIMES:
        raise ScaffoldError(f"generated manifest runtime {data.get('runtime')!r} not in {RUNTIMES}")
    serve = data.get("serve")
    if serve is not None:
        if not isinstance(serve, dict):
            raise ScaffoldError("generated manifest serve: is not a mapping")
        port = serve.get("port")
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
            raise ScaffoldError(f"generated manifest serve.port {port!r} is not 1-65535")
        health = serve.get("health_path")
        if not isinstance(health, str) or not health.startswith("/"):
            raise ScaffoldError(f"generated manifest serve.health_path {health!r} is not a path")
    checks = data.get("checks")
    if checks is not None:
        if not isinstance(checks, dict):
            raise ScaffoldError("generated manifest checks: is not a map")
        for name, argv in checks.items():
            if not isinstance(argv, list):
                raise ScaffoldError(f"generated manifest check {name!r} is not an argv list")
    return data


# ── skeleton materialisation ─────────────────────────────────────────────────


def write_file(root: Path, rel: str, content: str, name: str) -> None:
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content.replace("{{name}}", name))


def seed_skeleton(root: Path, name: str, runtime: str) -> list[str]:
    written = []
    for rel, content in SKELETON[runtime].items():
        write_file(root, rel, content, name)
        written.append(rel)
    return written


# ── the two paths ────────────────────────────────────────────────────────────


def create_new(owner: str, name: str, visibility: str, runtime: str,
               serve: dict | None, checks: list[str] | None) -> list[str]:
    tmp = Path(tempfile.mkdtemp(prefix="sssf-scaffold-"))
    try:
        written = seed_skeleton(tmp, name, runtime)
        manifest = manifest_text(runtime, serve, checks)
        validate_manifest(manifest)          # BEFORE anything leaves the machine
        (tmp / "sssf.app.yaml").write_text(manifest)
        (tmp / ".gitignore").write_text(GITIGNORE)
        written += ["sssf.app.yaml", ".gitignore"]

        run(["git", "init", "-b", "main"], cwd=tmp)
        run(["git", "add", "-A"], cwd=tmp)
        git_commit(tmp, f"Initial commit: sssf-sbx scaffolded {runtime} app")
        # gh handles remote creation + push to main from the source dir.
        run(["gh", "repo", "create", f"{owner}/{name}", f"--{visibility}",
             "--source=.", "--push"], cwd=tmp, echo=True)
        return written
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def is_meta_file(rel: str) -> bool:
    base = Path(rel).name.lower()
    return base.startswith("readme") or base.startswith("license") or base == ".gitignore"


def adopt_existing(owner: str, name: str, default_branch: str, runtime: str,
                   serve: dict | None, checks: list[str] | None) -> list[str]:
    """Clone, then ADD only what is missing. Never overwrite an existing file
    without an explicit yes, and never touch anything already tracked."""
    tmp = Path(tempfile.mkdtemp(prefix="sssf-scaffold-"))
    added: list[str] = []
    wrote_manifest = False
    try:
        run(["gh", "repo", "clone", f"{owner}/{name}", str(tmp)])
        tracked = run(["git", "ls-files"], cwd=tmp).stdout.split()
        empty_ish = all(is_meta_file(f) for f in tracked)

        manifest = manifest_text(runtime, serve, checks)
        validate_manifest(manifest)          # a scaffold bug fails before writing
        manifest_path = tmp / "sssf.app.yaml"
        if manifest_path.exists():
            if ask_yn("sssf.app.yaml already exists — overwrite?", False):
                manifest_path.write_text(manifest)
                added.append("sssf.app.yaml")
                wrote_manifest = True
            else:
                print("  keeping the existing sssf.app.yaml")
        else:
            manifest_path.write_text(manifest)
            added.append("sssf.app.yaml")
            wrote_manifest = True

        if empty_ish:
            for rel, content in SKELETON[runtime].items():
                if (tmp / rel).exists():
                    continue
                write_file(tmp, rel, content, name)
                added.append(rel)
        else:
            print("  repo is not empty — adding only sssf.app.yaml (skeleton skipped)")

        if not (tmp / ".gitignore").exists():
            (tmp / ".gitignore").write_text(GITIGNORE)
            added.append(".gitignore")

        if not added:
            print("  nothing to add — the repo already has a manifest and .gitignore")
            return added

        # Re-parse the final on-disk manifest before any push (the overwrite
        # answer could have come from the repo, not from us — either way the
        # file that ships must parse).
        final = (tmp / "sssf.app.yaml").read_text()
        if wrote_manifest:
            validate_manifest(final)
        run(["git", "add", "-A"], cwd=tmp)
        suffix = " + skeleton" if any(not is_meta_file(f) and f != "sssf.app.yaml" for f in added) else ""
        git_commit(tmp, f"sssf-sbx scaffold: add manifest{suffix} for {runtime} runtime")
        run(["git", "push", "origin", f"HEAD:{default_branch}"], cwd=tmp, echo=True)
        return added
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ── private-repo token ───────────────────────────────────────────────────────


def env_has_app_repo_token() -> bool:
    """The .env FILE is what persists — dotenv-load also exports it, but a file
    line is what survives a shell restart, so that is what we check."""
    if not ENV_FILE.is_file():
        return False
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("APP_REPO_GIT_TOKEN=") and line.split("=", 1)[1].strip():
            return True
    return False


def check_private_token() -> None:
    if env_has_app_repo_token():
        print("[scaffold] private repo: APP_REPO_GIT_TOKEN is set in .env")
        return
    print("[scaffold] WARNING: this repo is private but APP_REPO_GIT_TOKEN is not set in .env.")
    print("           `just sbx lifecycle fill` will fail FILL with APP_REPO_PRIVATE_NO_TOKEN")
    print("           (the sandbox clones the app with that token; public repos need none).")
    if ask_yn("add APP_REPO_GIT_TOKEN from 'gh auth token' to .env now?", False):
        token = run(["gh", "auth", "token"]).stdout.strip()
        if not token:
            raise ScaffoldError("gh auth token returned nothing — run 'gh auth login' first")
        existing = ENV_FILE.read_text().splitlines() if ENV_FILE.is_file() else []
        existing.append(f"APP_REPO_GIT_TOKEN={token}")
        ENV_FILE.write_text("\n".join(existing) + "\n")
        # Line number only — the token is NEVER printed.
        print(f"[scaffold] appended APP_REPO_GIT_TOKEN to .env (line {len(existing)}; value not shown)")
    else:
        print("           to fix it yourself, add this line to .env:")
        print("             APP_REPO_GIT_TOKEN=<a token with repo read — e.g. the output of: gh auth token>")


# ── roster ───────────────────────────────────────────────────────────────────


def write_roster(owner: str, name: str, ref: str, visibility: str) -> Path:
    roster = ROSTERS_DIR / f"sssf.{name}.config.yaml"
    if roster.exists():
        raise ScaffoldError(
            f"roster {roster.relative_to(REPO_ROOT)} already exists — remove it or "
            "pick another repo name (scaffold never overwrites a roster)"
        )

    template = TEMPLATE.read_text().splitlines()
    try:
        app_idx = next(i for i, line in enumerate(template) if line.startswith("app:"))
        agents_idx = next(i for i, line in enumerate(template) if line.startswith("agents:"))
    except StopIteration:
        raise ScaffoldError(
            f"template {TEMPLATE.relative_to(REPO_ROOT)} has no app:/agents: block — is this an sssf-sbx checkout?"
        ) from None

    # Flat two-space keys: mount.just and manage/mod.just parse this block with
    # awk, not YAML. The comment stays on the repo line so `print $2` is the URL.
    block = [
        "app:",
        f"  repo: https://github.com/{owner}/{name}.git   # scaffolded {visibility} repo",
        f"  ref: {ref}",
        "  path: target",
        "  manifest: sssf.app.yaml",
        "",
    ]
    body = template[:app_idx] + block + template[agents_idx:]
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    header = [
        f"# sssf.{name}.config.yaml — SCAFFOLDED by 'just sbx scaffold' on {today}",
        f"# app repo: https://github.com/{owner}/{name} ({visibility}) — everything below is the shipped hello template with the app: block filled in.",
    ]
    text = "\n".join(header + body) + "\n"

    data = yaml.safe_load(text) or {}
    app = data.get("app") or {}
    expected = {
        "repo": f"https://github.com/{owner}/{name}.git",
        "ref": ref,
        "path": "target",
        "manifest": "sssf.app.yaml",
    }
    for key, want in expected.items():
        if app.get(key) != want:
            raise ScaffoldError(f"generated roster app.{key} is {app.get(key)!r}, expected {want!r}")

    roster.write_text(text)
    rel = str(roster.relative_to(REPO_ROOT))
    run(["git", "add", "--", rel], cwd=REPO_ROOT)
    run(["git", "commit", "-m", f"Add scaffolded roster for {owner}/{name}", "--", rel], cwd=REPO_ROOT)
    sha = run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO_ROOT).stdout.strip()
    print(f"[scaffold] committed roster: {rel} ({sha})")
    return roster


# ── preflight ────────────────────────────────────────────────────────────────

GH_USER = ""


def preflight() -> None:
    global GH_USER
    if not shutil.which("gh"):
        raise ScaffoldError(
            "gh CLI not found — install it from https://cli.github.com and run 'gh auth login' first"
        )
    status = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if status.returncode != 0:
        raise ScaffoldError("gh is not authenticated — run 'gh auth login' first")
    GH_USER = run(["gh", "api", "user", "--jq", ".login"]).stdout.strip()
    if not GH_USER:
        raise ScaffoldError("could not resolve the gh account (gh api user --jq .login returned nothing)")
    if not TEMPLATE.is_file() or not PROBE_MOD_JUST.is_file():
        raise ScaffoldError(
            "not an sssf-sbx checkout: adws/adw_sssf_config/sssf.hello.config.yaml and "
            "just/sandbox/mod.just must exist — run this from the kernel repo root"
        )


def main(argv: list[str]) -> int:
    preflight()
    prefill = argv[0] if argv else ""

    print(f"[scaffold] scaffolding against the gh account '{GH_USER}'")

    # ── 1. repo name ─────────────────────────────────────────────────────────
    while True:
        raw = ask("repo (owner/name, or a bare name in " + GH_USER + ")", prefill)
        if "/" in raw:
            owner, _, name = raw.partition("/")
        else:
            owner, name = GH_USER, raw
        if not OWNER_RE.match(owner) or not NAME_RE.match(name):
            print("  invalid name — owner is alphanumeric with single internal dashes;"
                  " repo is [A-Za-z0-9_.-]+")
            prefill = ""
            continue
        break

    # ── 2. exists / create + visibility ──────────────────────────────────────
    # Accept the single-letter shorthands `e`/`c` as well as the full words.
    mode = ask_choice("repo exists or create-new", ("exists", "create"), "create",
                      aliases={"e": "exists", "c": "create"})
    default_branch = "main"
    if mode == "exists":
        view = subprocess.run(
            ["gh", "repo", "view", f"{owner}/{name}", "--json", "isPrivate,defaultBranchRef"],
            capture_output=True, text=True,
        )
        if view.returncode != 0:
            raise ScaffoldError(
                f"cannot reach {owner}/{name} — if it is private, gh needs access; if the "
                "mount will clone it from a sandbox, the host .env needs APP_REPO_GIT_TOKEN "
                "(a token with repo read on that repo)"
            )
        info = yaml.safe_load(view.stdout) or {}          # gh emits JSON; yaml parses it
        is_private = bool(info.get("isPrivate"))
        branch = (info.get("defaultBranchRef") or {}).get("name") or "main"
        default_branch = branch
        visibility = "private" if is_private else "public"
        print(f"  found {owner}/{name} ({visibility}, default branch '{default_branch}')")
    else:
        visibility = ask_choice("visibility", ("public", "private"), "public")

    # ── 3. runtime ───────────────────────────────────────────────────────────
    runtime = ask_choice("runtime", RUNTIMES, "bun")

    # ── 4. serve ─────────────────────────────────────────────────────────────
    serve_default = runtime in ("bun", "node")
    serve = None
    if ask_yn("serve", serve_default):
        command = ask("serve command", SERVE_CMD_DEFAULT[runtime])
        while not command:
            command = ask("serve command (required when serve is on)", "")
        while True:
            raw_port = ask("serve port", "4501")
            try:
                port = int(raw_port)
            except ValueError:
                print("  port must be an integer 1-65535")
                continue
            if not 1 <= port <= 65535:
                print("  port must be an integer 1-65535")
                continue
            break
        while True:
            health_path = ask("serve health path", "/")
            if health_path.startswith("/"):
                break
            print("  health path must start with '/'")
        serve = {"command": command, "port": port, "health_path": health_path}

    # ── 5. checks ────────────────────────────────────────────────────────────
    checks = None
    default_checks = CHECK_BY_RUNTIME[runtime]
    if default_checks is None:
        print("  runtime 'none': no skeleton test — the manifest declares no checks:")
    elif ask_yn(f"add the default test check ({' '.join(default_checks)})?", True):
        checks = default_checks

    # ── 6. summary + the one gate ────────────────────────────────────────────
    roster_rel = f"adws/adw_sssf_config/sssf.{name}.config.yaml"
    print("\n──────────────────────────────────────────────────────────────")
    print(f"  repo:        {owner}/{name}")
    print(f"  route:       {mode}")
    print(f"  visibility:  {visibility}")
    print(f"  runtime:     {runtime}")
    print(f"  ref:         {default_branch}")
    print(f"  serve:       {'off' if serve is None else serve['command'] + ' on :' + str(serve['port']) + serve['health_path']}")
    print(f"  checks:      {'none' if checks is None else 'test: ' + ' '.join(checks)}")
    print(f"  manifest:    sssf.app.yaml (validated before any push)")
    if mode == "create":
        print(f"  actions:     gh repo create {owner}/{name} --{visibility} --push")
    else:
        print(f"  actions:     gh repo clone {owner}/{name}; add ONLY missing files;")
        print(f"               commit + push origin HEAD:{default_branch}")
    print(f"  roster:      {roster_rel} (written + committed to this repo)")
    if visibility == "private":
        token_state = "present" if env_has_app_repo_token() else "MISSING — will offer to add"
        print(f"  APP_REPO_GIT_TOKEN: {token_state}")
    print("──────────────────────────────────────────────────────────────")
    if not ask_yn("proceed?", False):
        print("[scaffold] aborted — nothing was created or pushed", file=sys.stderr)
        return 1

    # ── 2'. build the payload and land it ────────────────────────────────────
    if mode == "create":
        files = create_new(owner, name, visibility, runtime, serve, checks)
        print(f"[scaffold] created {owner}/{name} ({visibility}) — {len(files)} files pushed")
    else:
        added = adopt_existing(owner, name, default_branch, runtime, serve, checks)
        if added:
            print(f"[scaffold] updated {owner}/{name} — added: {', '.join(added)}")
        else:
            print(f"[scaffold] {owner}/{name} already satisfied — nothing pushed")

    # ── 3'. private-repo token ───────────────────────────────────────────────
    if visibility == "private":
        check_private_token()

    # ── 4'. roster ───────────────────────────────────────────────────────────
    write_roster(owner, name, default_branch, visibility)

    # ── 5'. finish ───────────────────────────────────────────────────────────
    print(f"\n[scaffold] done — {owner}/{name} ({visibility}) + roster {roster_rel} (committed)\n")
    print("next steps:")
    print(f"  1. add to .env:   SSSF_CONFIG={roster_rel}")
    print("  2. preflight:     just sbx manage doctor")
    print("  3. mount:         just sbx mount <run-id>")
    print("lanes: 'just sbx run agent' steers; 'just sbx lifecycle execute' is the factory.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except InputClosed:
        print("[scaffold] input closed (EOF) — aborting, nothing done yet", file=sys.stderr)
        sys.exit(1)
    except ScaffoldError as error:
        print(f"[scaffold] {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("[scaffold] interrupted — aborting", file=sys.stderr)
        sys.exit(130)
