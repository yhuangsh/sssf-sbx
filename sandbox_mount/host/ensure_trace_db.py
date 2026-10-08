#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pydantic", "python-dotenv", "pyyaml", "rich"]
# ///
"""ensure_trace_db.py — create a project's sssf.db with the full Tracer schema.

One implementation, two callers: sandbox_mount/host/local_ui.py (before
launching the visualizer) and just/local.just's mount recipe (after its
preflight). Idempotent — Tracer's DDL is CREATE TABLE IF NOT EXISTS plus
additive migrations, so opening an existing db is a no-op.

Usage:
    uv run sandbox_mount/host/ensure_trace_db.py <db-path>

The path is expanduser'd and, when relative, resolved against the repo root so
the helper is cwd-independent. All prose goes to STDERR: caller local_ui.py's
stdout is eval'd by the just recipe and must carry only the KEY=value lines.
Exit 0 on success, 1 on usage error.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]  # sandbox_mount/host/ -> repo root
sys.path.insert(0, str(REPO_ROOT / "adws"))       # the `uv run adws/adw_*.py` import root

from adw_modules.tracer import Tracer


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: uv run sandbox_mount/host/ensure_trace_db.py <db-path>", file=sys.stderr)
        return 1
    db = Path(argv[0]).expanduser()
    if not db.is_absolute():
        db = (REPO_ROOT / db).resolve()
    existed = db.is_file()
    # Tracer mkdirs the db parent, creates the schema (CREATE TABLE IF NOT EXISTS
    # + additive migrations), and creates the events file's parent dir. Passing
    # the sessions dir itself leaves no stray session behind — same trick as
    # sandbox_mount/guest/provision.sh step 7/9.
    tracer = Tracer(db, db.parent / "sessions" / "events.jsonl")
    tracer.conn.close()
    if existed:
        print(f"→ trace db: {db} (already present — schema verified)", file=sys.stderr)
    else:
        print(f"→ trace db: initialized fresh {db} (empty — no runs yet)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
