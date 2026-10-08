#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""serve_ports.py — read-only per-project app serve-port awareness.

Every LOCAL roster (a roster with `app.local_path` set) points at an app clone
whose `sssf.app.yaml` may declare a `serve.port`. Two local projects that both
declare the same port, or a port already held by some other process, will make
the second app fail to bind — and the kernel cannot rebind an app's port. So
this is a READ-ONLY check: it prints the per-project port map and a named
WARNING with corrective instructions, and never blocks.

Scanned rosters (deduped):
    adws/adw_sssf_config/sssf*.config.yaml
    ./sssf*.config.yaml                       (scaffold writes here)

Exit 0 always (warnings are the contract); non-zero only on usage error.

Used by `just local doctor` (WARN-only) and `just local mount` (non-blocking).
"""

from __future__ import annotations

import socket
import sys
from pathlib import Path

import yaml

# sandbox_mount/host/serve_ports.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_DIR = REPO_ROOT / "adws" / "adw_sssf_config"


def project_key(roster: Path) -> str:
    name = roster.name
    if name.startswith("sssf."):
        name = name[len("sssf."):]
    if name.endswith(".config.yaml"):
        name = name[: -len(".config.yaml")]
    return name or "kernel"


def rosters() -> list[Path]:
    found: dict[Path, Path] = {}
    for directory in (CONFIG_DIR, REPO_ROOT):
        if not directory.is_dir():
            continue
        for pattern in ("sssf.*.config.yaml", "sssf.config.yaml"):
            for path in sorted(directory.glob(pattern)):
                if path.is_file():
                    found.setdefault(path.resolve(), path)
    return list(found.values())


def load_yaml(path: Path) -> dict:
    try:
        return yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError):
        return {}


def resolve_local(rel: str) -> Path:
    path = Path(rel).expanduser()
    if not path.is_absolute():
        path = REPO_ROOT / path
    return path


def collect() -> list[tuple[str, int, Path]]:
    """The port map: (key, serve.port, manifest path), one entry per declaration."""
    entries: list[tuple[str, int, Path]] = []
    for roster in rosters():
        cfg = load_yaml(roster)
        app = cfg.get("app") or {}
        local = app.get("local_path")
        if not local:
            continue
        key = project_key(roster)
        manifest_name = app.get("manifest") or "sssf.app.yaml"
        manifest = resolve_local(str(local)) / manifest_name
        if not manifest.is_file():
            print(f"  {key}: manifest not found at {manifest} (clone not present yet)")
            continue
        data = load_yaml(manifest)
        serve = data.get("serve") or {}
        if not isinstance(serve, dict):
            serve = {}
        port = serve.get("port")
        if port is None:
            print(f"  {key}: no serve: block in {manifest}")
            continue
        try:
            port = int(port)
        except (TypeError, ValueError):
            print(f"  {key}: serve.port {port!r} is not an integer ({manifest})")
            continue
        entries.append((key, port, manifest))
    return entries


def warn(message: str, correction: str) -> None:
    print(message, file=sys.stderr)
    print(f"  {correction}", file=sys.stderr)


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        print("usage: uv run sandbox_mount/host/serve_ports.py", file=sys.stderr)
        return 1

    entries = collect()

    print("[serve-port] local projects:")
    if not entries:
        print("  (no local rosters with app.local_path found)")
    for key, port, manifest in entries:
        print(f"  {key}  serve.port {port}  ({manifest})")

    # Declared collisions: the same port declared by more than one project.
    by_port: dict[int, list[tuple[str, Path]]] = {}
    for key, port, manifest in entries:
        by_port.setdefault(port, []).append((key, manifest))
    for port, decls in sorted(by_port.items()):
        if len(decls) < 2:
            continue
        names = [f"'{key}' ({manifest})" for key, manifest in decls]
        header = ", ".join(names[:-1]) + f" and {names[-1]}"
        manifests = " or ".join(dict.fromkeys(str(m) for _, m in decls))
        warn(
            f"WARNING [serve-port] collision: port {port} declared by {header}",
            "either stop the other project's server, or change serve.port in "
            f"{manifests}, or run yours with PORT=<free> if the app honors it",
        )

    # Live-bound: something is already listening on a declared port.
    for key, port, manifest in entries:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            bound = sock.connect_ex(("127.0.0.1", port)) == 0
        if bound:
            warn(
                f"WARNING [serve-port] port {port} declared by '{key}' is currently "
                f"bound on this host — if that server is not '{key}'s own",
                "either stop the other project's server, or change serve.port in "
                f"{manifest}, or run yours with PORT=<free> if the app honors it",
            )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
