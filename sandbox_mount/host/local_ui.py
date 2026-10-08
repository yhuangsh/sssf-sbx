#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""local_ui.py — resolve a project's visualizer db + a stable port pair.

Usage:
    uv run sandbox_mount/host/local_ui.py <roster-path>

Prints exactly three shlex-quoted assignments to stdout for the calling recipe
to `eval`:

    DB=/abs/path/to/<project>/sssf.db
    UI_PORT=4620
    API_PORT=4621

All human prose and warnings go to STDERR. Exit codes:
    0   proceed to start the visualizer on UI_PORT (api API_PORT, db DB)
    10  a visualizer for THIS db is already running; the recipe maps 10 -> 0
    1   usage / roster-resolution error

Port policy: the recorded integer P in <db dir>/ui.port is the user-facing vite
port; the API server binds P+1. A pair is usable only if BOTH ports are free
(probed by binding 0.0.0.0 without SO_REUSEADDR). Allocation scans upward from
4620. A recorded P held by something that is not our visualizer triggers the
named WARNING and an auto-bump; a re-run against a live instance is idempotent
(URL printed to stderr, exit 10).
"""

from __future__ import annotations

import json
import shlex
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

# sandbox_mount/host/local_ui.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[2]
PORT_BASE = 4620
HEALTH_TIMEOUT = 1.5


def project_key(roster: Path) -> str:
    """sssf.<key>.config.yaml -> <key>; the bare sssf.config.yaml -> kernel."""
    name = roster.name
    if name.startswith("sssf."):
        name = name[len("sssf."):]
    if name.endswith(".config.yaml"):
        name = name[: -len(".config.yaml")]
    return name or "kernel"


def resolve_db(roster: Path) -> Path:
    try:
        cfg = yaml.safe_load(roster.read_text()) or {}
    except FileNotFoundError:
        print(f"[local ui] roster not found: {roster}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as error:
        print(f"[local ui] roster is not valid YAML: {roster} ({error})", file=sys.stderr)
        sys.exit(1)
    rel = ((cfg.get("observability") or {}).get("db")) or "adws/adw_data/sssf.db"
    path = Path(str(rel)).expanduser()
    if not path.is_absolute():
        path = REPO_ROOT / path
    return path.resolve()


def port_free(port: int) -> bool:
    """True if we can bind 0.0.0.0:port without SO_REUSEADDR (nothing listening)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("0.0.0.0", port))
        except OSError:
            return False
    return True


def pair_free(port: int) -> bool:
    """A UI/API pair is usable only if BOTH ports bind."""
    return port_free(port) and port_free(port + 1)


def read_recorded(port_file: Path) -> int | None:
    if not port_file.is_file():
        return None
    try:
        value = int(port_file.read_text().strip())
    except (ValueError, OSError):
        return None
    return value if 1 <= value <= 65534 else None


def health_db(api_port: int) -> str | None:
    """The db path reported by GET /api/health, or None if nothing healthy answers."""
    url = f"http://127.0.0.1:{api_port}/api/health"
    try:
        with urllib.request.urlopen(url, timeout=HEALTH_TIMEOUT) as response:
            if response.status != 200:
                return None
            body = json.loads(response.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None
    return body.get("db") if isinstance(body, dict) else None


def first_free_pair(start: int) -> int:
    port = start
    while port + 1 <= 65535:
        if pair_free(port):
            return port
        port += 1
    print(f"[local ui] no free port pair found from {start} upward", file=sys.stderr)
    sys.exit(1)


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: uv run sandbox_mount/host/local_ui.py <roster-path>", file=sys.stderr)
        return 1
    roster = Path(argv[0])
    if not roster.is_absolute():
        roster = (Path.cwd() / roster).resolve()
    key = project_key(roster)
    db = resolve_db(roster)
    port_file = db.parent / "ui.port"
    print(f"→ project: {key}", file=sys.stderr)
    print(f"→ db:      {db}", file=sys.stderr)

    recorded = read_recorded(port_file)

    # Idempotency: a live visualizer for THIS db already owns the recorded pair.
    if recorded is not None and health_db(recorded + 1) == str(db):
        print(
            f"→ visualizer already running: http://localhost:{recorded} "
            f"(api :{recorded + 1}, db: {db})",
            file=sys.stderr,
        )
        return 10

    # Choose a port: reuse a free recorded pair; else allocate.
    if recorded is not None and pair_free(recorded):
        port = recorded
    elif recorded is None:
        port = first_free_pair(PORT_BASE)
    else:
        # Recorded, but held by something that is not our visualizer: bump.
        port = first_free_pair(max(recorded + 2, PORT_BASE))
        print(
            f"[local ui] WARNING: recorded port {recorded} for project '{key}' "
            f"is held by a process that is not our visualizer — moving to {port} "
            f"(recorded in {port_file})",
            file=sys.stderr,
        )

    port_file.parent.mkdir(parents=True, exist_ok=True)
    port_file.write_text(f"{port}\n")

    print(f"→ visualizer: http://localhost:{port}  (api :{port + 1}, db: {db})", file=sys.stderr)
    print(f"DB={shlex.quote(str(db))}")
    print(f"UI_PORT={shlex.quote(str(port))}")
    print(f"API_PORT={shlex.quote(str(port + 1))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
