#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""Side-by-side report for two or more runs — read-only.

`just sbx manage compare <id1> <id2> ...` is the ranking view for competing
fan-out arms: for each run it prints the outcome, the commits BASE..HEAD with
messages, the diffstat, tokens + cost, and the issue link, so a best-of-N
decision reads off one screen instead of a scavenger hunt.

READ-ONLY, HOST-SIDE ONLY. It never touches a VM (no ssh), never writes a ref,
never runs a check. Commits come from the harvested app cache
(<state root or .sandbox>/repos/<app>.git, ref refs/sandbox/<id>) or, failing
that, from the local clone (refs/harvest/<id> / local/<id>). Tokens/cost come
from the pulled artifact trace db when a teardown has copied it.
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parent
REPO_ROOT = HOST_DIR.parents[1]
DEFAULT_DB_REL = "adws/adw_data/sssf.db"

# run_record.py is the sanctioned store. Import it directly (host-side, stdlib);
# it also owns the state-root rule, so no .sandbox/runs is hardcoded here.
sys.path.insert(0, str(HOST_DIR))
import run_record  # noqa: E402


def _runs_dir() -> Path:
    return run_record.runs_dir()


def _cache_root() -> Path:
    root = run_record.state_root()
    return root if root is not None else run_record.LEGACY_RUNS_DIR.parent


def _roster() -> dict:
    roster = os.environ.get("SSSF_CONFIG", "").strip()
    if not roster or not Path(roster).is_file():
        return {}
    try:
        import yaml
        return yaml.safe_load(Path(roster).read_text()) or {}
    except Exception:
        return {}


def _app_repo() -> str:
    return str(((_roster().get("app") or {}).get("repo") or "")).strip()


def _app_local() -> str:
    local = str(((_roster().get("app") or {}).get("local_path") or "")).strip()
    return str(Path(local).expanduser()) if local else ""


def _roster_db_rel() -> str:
    db = (_roster().get("observability") or {}).get("db")
    return str(db) if db else DEFAULT_DB_REL


def _git(repo: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def _find_ref(run_id: str) -> tuple[str, str]:
    """(repo, ref) holding the run's commits, or ("", "") when not harvested."""
    app_repo = _app_repo()
    if app_repo:
        bn = app_repo.rstrip("/").rsplit("/", 1)[-1]
        if bn.endswith(".git"):
            bn = bn[:-4]
        cache = _cache_root() / "repos" / f"{bn}.git"
        if cache.is_dir() and _git(str(cache), "rev-parse", "--verify", "--quiet",
                                   f"refs/sandbox/{run_id}").returncode == 0:
            return str(cache), f"refs/sandbox/{run_id}"
    local = _app_local()
    if local and Path(local, ".git").exists():
        for ref in (f"refs/harvest/{run_id}", f"local/{run_id}", f"sbx/{run_id}"):
            if _git(local, "rev-parse", "--verify", "--quiet", ref).returncode == 0:
                return local, ref
    return "", ""


def _tokens_cost(run_id: str) -> str:
    db = _runs_dir() / f"{run_id}-artifacts" / _roster_db_rel()
    if not db.is_file():
        return "n/a (no artifact db)"
    try:
        con = sqlite3.connect(str(db))
        row = con.execute("select total_tokens, total_cost, status from sessions "
                          "order by started_at desc limit 1").fetchone()
        con.close()
    except sqlite3.Error as e:
        return f"n/a ({e})"
    if not row:
        return "n/a (no sessions)"
    tokens = row[0] or 0
    try:
        cost = float(row[1] or 0)
    except (TypeError, ValueError):
        cost = 0.0
    status = row[2] or "?"
    return f"{tokens} tokens, ${cost:.4f} (status {status})"


def _harvest_line(rec: dict) -> str:
    state = rec.get("harvest_state")
    base = rec.get("base_ref") or "main"
    sha = rec.get("merge_sha")
    if state == "merged":
        return f"merged into {base} as {sha}"
    if state == "harvested-unmerged":
        return f"harvested-unmerged (conflict merging into {base})"
    if state == "merge-broke-build":
        return f"merge-broke-build (reverted; merge sha {sha})"
    if state == "bundle-only":
        return "bundle-only (awaiting integration decision)"
    return "not harvested"


def _block(run_id: str) -> str:
    try:
        rec = run_record.get(run_id)
    except FileNotFoundError:
        return f"═══ {run_id} ═══\n  no run record — skipping"
    out = [f"═══ {run_id} ═══"]
    out.append(f"  outcome:    {rec.get('issue_state') or 'unknown'}")
    if rec.get("issue_url"):
        out.append(f"  issue:      {rec['issue_url']}")
    out.append(f"  harvest:    {_harvest_line(rec)}")

    base = rec.get("commit_sha")
    repo, ref = _find_ref(run_id)
    if not repo or not base:
        out.append("  commits:    not harvested — run `just sbx manage harvest "
                    f"{run_id}`")
    else:
        out.append(f"  commits ({base[:10]}..{ref}):")
        r = _git(repo, "log", "--format=%h %s", f"{base}..{ref}")
        lines = [l for l in r.stdout.splitlines() if l.strip()]
        if lines:
            out.extend(f"    {l}" for l in lines)
        else:
            out.append("    (none)")
        out.append("  diffstat:")
        r = _git(repo, "diff", "--stat", f"{base}..{ref}")
        out.extend(f"    {l}" for l in r.stdout.splitlines() if l.strip())
    out.append(f"  tokens/cost: {_tokens_cost(run_id)}")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Compare two or more harvested runs")
    p.add_argument("run_ids", nargs="+")
    args = p.parse_args(argv)
    if len(args.run_ids) < 2:
        print("compare: need at least two run ids", file=sys.stderr)
        return 2
    print("\n\n".join(_block(rid) for rid in args.run_ids))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
