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

HOST_DIR = Path(__file__).resolve().parent          # sandbox_mount/host/
REPO_ROOT = HOST_DIR.parents[1]                     # -> repo root
sys.path.insert(0, str(REPO_ROOT / "adws"))         # the `uv run adws/adw_*.py` import root
sys.path.insert(0, str(HOST_DIR))                   # run_record.py, for the state-root rule

from adw_modules.tracer import Tracer

# The historical kernel default. A caller that names THIS path means "default";
# an app run re-homes it under the state root.
DEFAULT_DB_REL = "adws/adw_data/sssf.db"


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: uv run sandbox_mount/host/ensure_trace_db.py <db-path>", file=sys.stderr)
        return 1
    raw = argv[0]
    db = Path(raw).expanduser()
    if not db.is_absolute():
        db = (REPO_ROOT / db).resolve()
    # State-root re-homing: when the active roster resolves a per-app root and
    # the caller asked for the plain kernel default, materialize the db there
    # instead — the same place session.py writes it for a local app run.
    try:
        import run_record
        root = run_record.state_root()
        if raw == DEFAULT_DB_REL and root is not None:
            db = root / "sssf.db"
    except Exception:
        pass  # never let db resolution block db creation
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
