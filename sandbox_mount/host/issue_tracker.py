#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""GitHub-issue tracking for every ADW session — the durable audit record.

One issue per ADW session, in the APP'S OWN REPO (the roster's `app.repo`), so
the instruction -> outcome trail lives where the code does instead of in the
throwaway sandbox. This is HOST-SIDE ONLY: it wraps the `gh` CLI, which reads
the engineer's own host credential store. That credential never enters the VM —
the only thing this script asks a VM for is a read-only trace query over ssh
(python3 + stdlib sqlite3; no sqlite3 CLI is assumed on exeuntu).

Usage:
    issue_tracker.py open   RUN_ID --instruction TEXT [--chain NAME]
    issue_tracker.py update RUN_ID --milestone NAME [--db PATH]
    issue_tracker.py close  RUN_ID --outcome accepted|failed|cancelled [--db PATH] [--note TEXT]
    issue_tracker.py watch  RUN_ID --since ISO_TS
    issue_tracker.py sync

Everything is best-effort: a tracker failure warns and exits 0 so it can never
fail a mount/execute/teardown. `SSSF_ISSUES=0` disables the feature entirely;
a roster with no `app.repo` (vendored mode) skips with a named message because
there is no separate app repo to file into. Issue bodies are redacted against
every host env value whose NAME looks like a secret — the belt to the suspenders
of never assembling content from `.env` in the first place.

The script is a PEP-723 uv script (pyyaml only) and reuses run_record.py, the
one state file shared across the six sandbox phases, as its store — the tracker
extends that closed schema rather than inventing a second one.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn

HOST_DIR = Path(__file__).resolve().parent
REPO_ROOT = HOST_DIR.parents[1]

# run_record.py lives next to us and is the sanctioned store. Import it directly
# (both run on the host) so coercion + the closed schema stay in one place. It
# also owns the ONE state-root rule, so this file never hardcodes .sandbox/runs.
sys.path.insert(0, str(HOST_DIR))
import run_record  # noqa: E402


def _runs_dir() -> Path:
    """The run's record/artifact/bundle dir: the per-app state root's runs/ (or
    legacy .sandbox/runs/ in vendored mode). Resolved fresh — SSSF_CONFIG is read
    per call, exactly like run_record itself."""
    return run_record.runs_dir()


def _state_root_or_legacy_sandbox() -> Path:
    """Where host-side per-app state (harvest caches) lives: <root>/ or .sandbox/."""
    root = run_record.state_root()
    return root if root is not None else run_record.LEGACY_RUNS_DIR.parent


def _display(path: Path) -> str:
    """Path relative to the kernel repo when it is inside it, else absolute."""
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)

# The trace db inside the factory clone on the VM (provision.sh step 7), relative
# to the factory root. This is the fallback; _roster_db_rel() reads the active
# roster, and a namespaced local roster (adws/adw_data/local/<key>/sssf.db)
# overrides it so the tracker follows the run's own db — not the kernel's.
VM_DB_REL = "adws/adw_data/sssf.db"


def _roster_db_rel() -> str:
    """The active roster's observability.db (relative), best-effort fallback."""
    roster = os.environ.get("SSSF_CONFIG", "").strip()
    if roster and Path(roster).is_file():
        try:
            import yaml
            db = (yaml.safe_load(Path(roster).read_text()) or {}).get("observability") or {}
            rel = db.get("db")
            if rel:
                return str(rel)
        except Exception:
            pass
    return VM_DB_REL

# The five state labels. `--force` on create makes ensure_labels idempotent.
LABELS = {
    "sssf:running":   ("1d76db", "SSSF session in flight"),
    "sssf:accepted":  ("0e8a16", "SSSF session succeeded"),
    "sssf:failed":    ("d93f0b", "SSSF session failed"),
    "sssf:cancelled": ("fbca04", "SSSF session torn down mid-run"),
    "sssf:follow-up": ("5319e7", "SSSF re-run of a failed session"),
    "sssf:local":     ("0075ca", "SSSF session ran on the host (local mode)"),
    "sssf:merged-broken": ("d93f0b", "SSSF merge passed textually but broke the checks"),
}

_SECRET_NAME = re.compile(r"(KEY|TOKEN|SECRET|PASSWORD)", re.IGNORECASE)
_SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
             "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3"]

WATCH_INTERVAL = 30
WATCH_MAX_SECONDS = 6 * 3600

# Name families that mark the run as "past implementation" — the coarse moment a
# milestone comment is worth posting. review% is the proposal's example; test%/
# quality% cover the default `sdlc` chain (plan_build_test), which has no review
# phase at all.
VERIFY_PHASE = re.compile(r"^(review|test|quality|revise|fix|document)", re.IGNORECASE)


# ── tiny utilities ───────────────────────────────────────────────────────────
def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def warn(msg: str) -> None:
    print(f"!! issue_tracker: {msg}", file=sys.stderr)


def die(msg: str) -> NoReturn:
    print(f"issue_tracker: {msg}", file=sys.stderr)
    sys.exit(1)


def redact(text: str) -> str:
    """Replace every secret-looking host env VALUE with a marker.

    Issue content is assembled from instructions, run metadata, trace rows,
    commit subjects and error strings — never from `.env` — so in practice this
    finds nothing. It is the belt to that suspenders, and verification (h) for
    this feature asserts no secret value ever reaches a body.
    """
    if not text:
        return text
    for name, value in os.environ.items():
        if not _SECRET_NAME.search(name):
            continue
        if not value or len(value) < 8:
            continue
        text = text.replace(value, "***REDACTED***")
    return text


def _dur(start: str | None, end: str | None) -> str:
    if not start or not end:
        return ""
    try:
        a = datetime.fromisoformat(start.replace("Z", "+00:00"))
        b = datetime.fromisoformat(end.replace("Z", "+00:00"))
        secs = max(0.0, (b - a).total_seconds())
    except (ValueError, TypeError):
        return ""
    if secs < 60:
        return f"{secs:.1f}s"
    return f"{int(secs // 60)}m{int(secs % 60):02d}s"


# ── gh wrapper (host-side credential only) ──────────────────────────────────
def gh(args: list[str], input: str | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["gh", *args], capture_output=True, text=True, input=input)
    except FileNotFoundError:
        return subprocess.CompletedProcess(["gh", *args], 127, "", "gh not on PATH")


def gh_ok(args: list[str]) -> bool:
    return gh(args).returncode == 0


def gh_auth_ok() -> bool:
    return gh_ok(["auth", "status"])


def ensure_labels(repo: str) -> None:
    for name, (color, desc) in LABELS.items():
        gh(["label", "create", name, "--repo", repo, "--color", color,
            "--description", desc, "--force"])


def _issue_info(repo: str, number: int, comments: bool = False) -> dict | None:
    # gh 2.46 has no `stateReason` json field; the closed-as-failed signal is the
    # `sssf:failed` label, which is what we set on close.
    fields = "state,labels,url,title"
    if comments:
        fields += ",comments,body"
    r = gh(["issue", "view", str(number), "--repo", repo, "--json", fields])
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def _label_names(info: dict) -> list[str]:
    return [str(l.get("name")) for l in (info.get("labels") or [])]


def _repo_from_url(url: str | None) -> str:
    m = re.match(r"^(https?://[^/]+/[^/]+/[^/]+)/issues/\d+", url or "")
    return m.group(1) if m else ""


def _repo_from_record(rec: dict | None) -> str:
    if not rec:
        return ""
    return _repo_from_url(rec.get("issue_url"))


# ── roster resolution ───────────────────────────────────────────────────────
def _app_config() -> tuple[str, str, str]:
    """(app.repo, app.path, app.local_path) from the active roster. Raises with
    THE named error. local_path is expanded (~) and empty when unset — in LOCAL
    mode the payload is that clone, not `<repo_root>/<path>`."""
    path = os.environ.get("SSSF_CONFIG")
    if not path:
        raise RuntimeError(
            "SSSF_CONFIG is not set — point it at your roster (add "
            "'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, "
            "or export it inline). See README -> Arming.")
    try:
        import yaml
        data = yaml.safe_load(Path(path).read_text()) or {}
    except FileNotFoundError:
        raise RuntimeError(f"roster file not found: {path}") from None
    app = data.get("app") or {}
    repo = str(app.get("repo") or "").strip()
    app_path = str(app.get("path") or "").strip() or "target"
    local_path = str(app.get("local_path") or "").strip()
    if local_path:
        local_path = str(Path(local_path).expanduser())
    return repo, app_path, local_path


def _app_path_quiet() -> str:
    try:
        return _app_config()[1]
    except Exception:
        return "target"


def _local_path_quiet() -> str:
    try:
        return _app_config()[2]
    except Exception:
        return ""


def _is_local(rec: dict | None, explicit: bool = False) -> bool:
    """A run is local when the explicit flag is set OR its record says so — a
    `vm_name` of "local" (a free string; the sandbox lanes never set it). This
    is what keeps the tracker away from ssh to local.exe.xyz."""
    if explicit:
        return True
    return bool(rec and str(rec.get("vm_name") or "") == "local")


def _roster_name() -> str:
    return Path(os.environ.get("SSSF_CONFIG", "")).name or "(unknown)"


# ── run record ──────────────────────────────────────────────────────────────
def get_record(run_id: str) -> dict | None:
    try:
        return run_record.get(run_id)
    except FileNotFoundError as e:
        warn(str(e))
        return None


def set_record(run_id: str, **fields) -> None:
    try:
        run_record.set(run_id, **fields)
    except Exception as e:  # best-effort: a bad record write must not fail a phase
        warn(f"could not update the run record for {run_id}: {e}")


# ── trace access ────────────────────────────────────────────────────────────
_REMOTE_SCRIPT = r'''
import sqlite3, json
DB = __DB__
SINCE = __SINCE__
ADW = __ADW__
out = {"session": None, "phases": [], "gates": [], "envelopes": []}
try:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
except Exception as e:
    print(json.dumps({"error": str(e)}))
    raise SystemExit(0)


def q(sql, args=()):
    try:
        return [dict(r) for r in con.execute(sql, args)]
    except Exception:
        return []


if ADW:
    rows = q("SELECT * FROM sessions WHERE adw_id=? LIMIT 1", (ADW,))
elif SINCE:
    rows = q("SELECT * FROM sessions WHERE started_at >= ? ORDER BY started_at ASC LIMIT 1", (SINCE,))
else:
    rows = q("SELECT * FROM sessions ORDER BY started_at DESC LIMIT 1")
session = rows[0] if rows else None
adw = ADW or (session or {}).get("adw_id")
out["session"] = session
if adw:
    out["phases"] = q("SELECT seq,name,kind,owner,status,attempt,retries,error,started_at,ended_at "
                      "FROM phases WHERE adw_id=? ORDER BY seq", (adw,))
    out["gates"] = q("SELECT gate,passed,violations_json,checks_json,created_at "
                     "FROM gate_results WHERE adw_id=?", (adw,))
    out["envelopes"] = q("SELECT agent,output_type,payload_json,valid,attempt "
                         "FROM envelopes WHERE adw_id=? AND output_type LIKE '%eview%'", (adw,))
print(json.dumps(out))
'''


def _read_db(dbpath: str, since: str | None, adw: str | None) -> dict:
    """Read the trace from a local sqlite file (artifact copy / --db)."""
    import sqlite3

    out: dict = {"session": None, "phases": [], "gates": [], "envelopes": []}
    try:
        con = sqlite3.connect(dbpath)
        con.row_factory = sqlite3.Row
    except Exception as e:  # pragma: no cover - defensive
        out["error"] = str(e)
        return out

    def q(sql: str, args: tuple = ()) -> list[dict]:
        try:
            return [dict(r) for r in con.execute(sql, args)]
        except Exception:
            return []

    if adw:
        rows = q("SELECT * FROM sessions WHERE adw_id=? LIMIT 1", (adw,))
    elif since:
        rows = q("SELECT * FROM sessions WHERE started_at >= ? ORDER BY started_at ASC LIMIT 1",
                 (since,))
    else:
        rows = q("SELECT * FROM sessions ORDER BY started_at DESC LIMIT 1")
    session = rows[0] if rows else None
    out["session"] = session
    adw = adw or (session or {}).get("adw_id")
    if adw:
        out["phases"] = q("SELECT seq,name,kind,owner,status,attempt,retries,error,"
                          "started_at,ended_at FROM phases WHERE adw_id=? ORDER BY seq", (adw,))
        out["gates"] = q("SELECT gate,passed,violations_json,checks_json,created_at "
                         "FROM gate_results WHERE adw_id=?", (adw,))
        out["envelopes"] = q("SELECT agent,output_type,payload_json,valid,attempt "
                             "FROM envelopes WHERE adw_id=? AND output_type LIKE '%eview%'", (adw,))
    con.close()
    return out


def _ssh(host: str, command: str, timeout: int = 25) -> subprocess.CompletedProcess:
    dest = host if "." in host else host + ".exe.xyz"
    return subprocess.run(["ssh", *_SSH_OPTS, dest, command],
                          capture_output=True, text=True, timeout=timeout)


def _vm_trace(vm: str, since: str | None, adw: str | None,
              dbpath: str | None = None) -> dict:
    """Read the trace over ssh with python3 + stdlib sqlite3 (no sqlite3 CLI)."""
    if dbpath is None:
        dbpath = f"/home/exedev/app/{_roster_db_rel()}"
    script = (_REMOTE_SCRIPT
              .replace("__DB__", repr(dbpath))
              .replace("__SINCE__", repr(since))
              .replace("__ADW__", repr(adw)))
    dest = vm if "." in vm else vm + ".exe.xyz"
    r = subprocess.run(["ssh", *_SSH_OPTS, dest, "python3", "-"],
                       input=script, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        tail = (r.stderr or "ssh failed").strip().splitlines()
        raise RuntimeError(tail[-1][:300] if tail else "ssh failed")
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    if not lines:
        raise RuntimeError("no output from the VM trace query")
    return json.loads(lines[-1])


def _artifact_db(run_id: str) -> Path:
    return _runs_dir() / f"{run_id}-artifacts" / _roster_db_rel()


def _trace(run_id: str, db: str | None = None, since: str | None = None,
           adw: str | None = None, record: dict | None = None) -> dict:
    """Trace dict with session/phases/gates/envelopes plus source and commits.

    Priority: LOCAL mode reads the HOST db directly (never ssh — a vm_name of
    "local" would otherwise try local.exe.xyz); else an explicit --db copy
    (sync); else the live VM; else the teardown-pulled artifact copy. A VM that
    no longer answers falls through to the artifact copy rather than failing.
    """
    rec = record if record is not None else get_record(run_id)
    data: dict | None = None
    source = "none"
    if _is_local(rec):
        root = run_record.state_root()
        host_db = (root / "sssf.db") if root is not None else (REPO_ROOT / _roster_db_rel())
        if host_db.is_file():
            data, source = _read_db(str(host_db), since, adw), str(host_db)
    elif db and Path(db).is_file():
        data, source = _read_db(db, since, adw), str(db)
    elif rec and rec.get("vm_name"):
        try:
            data, source = _vm_trace(rec["vm_name"], since, adw), "vm"
        except Exception as e:
            warn(f"{run_id}: live trace read failed ({e}); trying the artifact copy")
    if data is None:
        art = _artifact_db(run_id)
        if art.is_file():
            data, source = _read_db(str(art), since, adw), str(art)
        else:
            data = {"session": None, "phases": [], "gates": [], "envelopes": []}
    data["source"] = source
    data["commits"] = _commits(run_id, rec) if rec else []
    return data


def _commits(run_id: str, rec: dict | None) -> list[str]:
    """BASE..HEAD commit subjects on the target run branch, best-effort."""
    if not rec:
        return []
    base = rec.get("commit_sha")
    if not base:
        return []
    if _is_local(rec):
        local = _local_path_quiet()
        if local:
            r = subprocess.run(["git", "-C", local, "log", "--format=%h %s",
                                f"{base}..HEAD"], capture_output=True, text=True)
            if r.returncode == 0:
                return [l for l in r.stdout.splitlines() if l.strip()]
        return []
    vm = rec.get("vm_name")
    if vm:
        repo_dir = f"app/{_app_path_quiet()}"
        cmd = (f"git -C {repo_dir} log --format='%h %s' {base}..HEAD 2>/dev/null "
               f"|| true")
        try:
            r = _ssh(vm, cmd)
            lines = [l for l in r.stdout.splitlines() if l.strip()]
            if lines:
                return lines
        except Exception:
            pass
    # Harvested cache: <state root or .sandbox>/repos/<app>.git with
    # refs/sandbox/<run_id>.
    repo = _repo_from_url(rec.get("issue_url")) or ""
    if not repo:
        try:
            repo, _, _ = _app_config()
        except Exception:
            repo = ""
    if repo:
        base_name = repo.rstrip("/").rsplit("/", 1)[-1]
        cache = _state_root_or_legacy_sandbox() / "repos" / f"{base_name}.git"
        if cache.is_dir():
            r = subprocess.run(["git", "-C", str(cache), "log", "--format=%h %s",
                                f"{base}..refs/sandbox/{run_id}"],
                               capture_output=True, text=True)
            if r.returncode == 0:
                return [l for l in r.stdout.splitlines() if l.strip()]
    return []


def _harvest_status(run_id: str, rec: dict | None, commits: list[str],
                    local: bool = False) -> str:
    if local:
        payload = _local_path_quiet() or "<local_path>"
        return (f"local mode — commits are on branch `local/{run_id}` in `{payload}`; "
                "push when ready (no bundle)")
    # The record's integration outcome wins when HARVEST has written one — it is
    # the durable truth (merged / harvested-unmerged / merge-broke-build /
    # bundle-only); the bundle line below is the backwards-compatible fallback.
    state = (rec or {}).get("harvest_state")
    base_ref = (rec or {}).get("base_ref") or "main"
    merge_sha = (rec or {}).get("merge_sha")
    if state == "merged":
        return (f"merged into `{base_ref}` as `{merge_sha}` — the merge is in the "
                "local clone only; push stays human")
    if state == "harvested-unmerged":
        return (f"harvested-unmerged — a conflict merging into `{base_ref}` was "
                "aborted; the run branch is fetched, resolve it manually")
    if state == "merge-broke-build":
        return (f"merge-broke-build — merged, then reverted after the checks failed"
                f"{f' (merge sha `{merge_sha}`)' if merge_sha else ''}; "
                "resolve the checks and re-apply the merge")
    if state == "bundle-only":
        return f"bundle-only — awaiting integration decision"
    bundle = _runs_dir() / f"{run_id}.bundle"
    if not bundle.is_file():
        return (f"not harvested — no bundle at `{_display(bundle)}` "
                "(run `just sbx manage harvest " + run_id + "`)")
    count = len(commits)
    suffix = f", {count} commit(s) in BASE..HEAD" if count else ""
    return f"harvested — bundle at `{bundle.relative_to(REPO_ROOT)}`{suffix}"


# ── issue body / comment rendering ──────────────────────────────────────────
def _fmt_phase_list(phases: list[dict]) -> str:
    if not phases:
        return "_(no phases recorded yet)_"
    lines = []
    for p in phases:
        dur = _dur(p.get("started_at"), p.get("ended_at"))
        bits = [f"`{p.get('seq')}` **{p.get('name') or '?'}**",
                f"({p.get('kind') or '?'}/{p.get('owner') or '?'})",
                f"— {p.get('status') or '?'}"]
        if p.get("attempt"):
            bits.append(f"attempt {p.get('attempt')}")
        if dur:
            bits.append(f"· {dur}")
        lines.append("- " + " ".join(bits))
    return "\n".join(lines)


def _fmt_cost(session: dict | None) -> str:
    s = session or {}
    tokens = s.get("total_tokens") or 0
    try:
        cost = float(s.get("total_cost") or 0)
    except (TypeError, ValueError):
        cost = 0.0
    return f"- tokens: **{tokens}**\n- cost: **${cost:.4f}**"


def _fmt_reviews(envelopes: list[dict]) -> str:
    if not envelopes:
        return "_(no review envelopes recorded)_"
    lines = []
    for e in envelopes:
        payload = {}
        try:
            payload = json.loads(e.get("payload_json") or "{}")
        except ValueError:
            payload = {}
        verdict = payload.get("approved")
        if verdict is None:
            verdict = payload.get("status") or "?"
        approved = "approved" if payload.get("approved") is True else (
            "rejected" if payload.get("approved") is False else str(verdict))
        summary = str(payload.get("summary") or "").strip()
        blocking = payload.get("blocking") or []
        entry = f"- **{e.get('agent') or '?'}** ({e.get('output_type') or '?'}): {approved}"
        if summary:
            entry += f" — {summary}"
        if blocking:
            entry += "\n  - blocking: " + "; ".join(str(b) for b in blocking)
        lines.append(entry)
    return "\n".join(lines)


def _fmt_commits(commits: list[str]) -> str:
    if not commits:
        return "_(no commits on the target run branch)_"
    return "\n".join(f"- `{c}`" for c in commits)


def _fmt_gates(gates: list[dict]) -> str:
    if not gates:
        return "_(no gate results recorded)_"
    lines = []
    for g in gates:
        passed = g.get("passed")
        mark = "pass" if passed else "FAIL"
        lines.append(f"- **{g.get('gate') or '?'}**: {mark}")
        if not passed:
            try:
                violations = json.loads(g.get("violations_json") or "[]")
            except ValueError:
                violations = []
            for v in violations:
                lines.append(f"  - violation: {v}")
            try:
                checks = json.loads(g.get("checks_json") or "[]")
            except ValueError:
                checks = []
            for c in checks:
                if isinstance(c, dict) and c.get("ok") is False:
                    note = c.get("note") or ""
                    lines.append(f"  - failed check: {c.get('item') or '?'} {note}".rstrip())
    return "\n".join(lines)


def _provenance_rows(rec: dict, chain: str | None, local: bool = False) -> str:
    if local:
        rows = [
            ("run id", rec.get("run_id")),
            ("roster", _roster_name()),
            ("factory sha", rec.get("factory_sha")),
            ("payload HEAD (base)", rec.get("commit_sha")),
            ("payload", _local_path_quiet() or "(local)"),
            ("chain", chain or "(filled at first update)"),
            ("created", rec.get("created_at")),
        ]
    else:
        rows = [
            ("run id", rec.get("run_id")),
            ("roster", _roster_name()),
            ("factory sha", rec.get("factory_sha")),
            ("target HEAD (base)", rec.get("commit_sha")),
            ("vm", rec.get("vm_name")),
            ("vm tag", rec.get("tag")),
            ("chain", chain or "(filled at first update)"),
            ("created", rec.get("created_at")),
        ]
    body = ["| field | value |", "|---|---|"]
    for k, v in rows:
        body.append(f"| {k} | {v if v not in (None, '') else '—'} |")
    return "\n".join(body)


def _open_body(rec: dict, instruction: str, chain: str | None, prev: int | None,
               local: bool = False) -> str:
    parts = []
    if prev:
        parts.append(f"> **Follow-up to #{prev}** — the previous session on this run "
                     f"record failed.")
    parts.append("## Instruction\n\n```text\n" + (instruction or "") + "\n```")
    parts.append("## Provenance\n\n" + _provenance_rows(rec, chain, local=local))
    return "\n\n".join(parts)


def _milestone_body(milestone: str, trace: dict) -> str:
    session = trace.get("session") or {}
    phases = trace.get("phases") or []
    return (f"<!-- sssf:milestone:{milestone} -->\n"
            f"## Milestone: {milestone}\n\n"
            f"_{_now()} · checkpoint comment from the host-side watcher._\n\n"
            f"### Phase timeline so far\n\n{_fmt_phase_list(phases)}\n\n"
            f"### Cost so far\n\n{_fmt_cost(session)}")


def _failure_forensics(trace: dict, rec: dict, local: bool = False) -> str:
    phases = trace.get("phases") or []
    failing = [p for p in phases if str(p.get("status")).lower() == "fail"]
    lines = ["### Failure forensics"]
    if failing:
        p = failing[0]
        lines.append(f"- **failing phase:** `{p.get('seq')}` {p.get('name')} "
                     f"({p.get('kind')}/{p.get('owner')}), attempt {p.get('attempt')}")
        if p.get("error"):
            lines.append("\n**error (verbatim):**\n\n```text\n"
                         + str(p.get("error")) + "\n```")
    else:
        lines.append("- **failing phase:** none recorded — the run failed on its "
                     "acceptance criterion (e.g. a red suite or an unapproved review).")
    lines.append("\n**gates:**\n\n" + _fmt_gates(trace.get("gates") or []))
    lines.append("\n**reviews:**\n\n" + _fmt_reviews(trace.get("envelopes") or []))
    state = rec.get("issue_state") or "failed"
    if local:
        payload = _local_path_quiet() or "<local_path>"
        lines.append(f"\n**surviving state:** the payload clone at `{payload}` on branch "
                     f"`local/{rec.get('run_id')}` survives (no VM); run record state "
                     f"`{state}`.")
    else:
        vm = rec.get("vm_name") or "gone"
        bundle = _runs_dir() / f"{rec.get('run_id')}.bundle"
        lines.append(f"\n**surviving state:** VM `{vm}` (left alive on failure unless torn "
                     f"down); run record state `{state}`; harvest bundle at "
                     f"`{_display(bundle)}` when harvest ran.")
    return "\n".join(lines)


def _outcome_reason(outcome: str, note: str | None, trace: dict) -> str:
    if outcome == "cancelled":
        return note or "cancelled at teardown"
    if outcome == "failed":
        failing = [p for p in (trace.get("phases") or [])
                   if str(p.get("status")).lower() == "fail"]
        if failing and failing[0].get("error"):
            return str(failing[0]["error"])
        return "the session ended with status fail"
    # accepted — there is no stored reason; surface the last envelope summary.
    envs = trace.get("envelopes") or []
    for e in reversed(envs):
        try:
            payload = json.loads(e.get("payload_json") or "{}")
        except ValueError:
            payload = {}
        if payload.get("summary"):
            return str(payload["summary"])
    return "all phases passed; session finished with status success"


def _final_comment(outcome: str, note: str | None, rec: dict, trace: dict,
                   local: bool = False) -> str:
    session = trace.get("session") or {}
    phases = trace.get("phases") or []
    commits = trace.get("commits") or []
    parts = [f"## Final outcome — `{outcome}`", f"_{_now()}_"]
    if outcome == "cancelled":
        parts.append(f"**State at teardown:** {note or 'cancelled at teardown'}")
    if outcome == "failed":
        parts.append(_failure_forensics(trace, rec, local=local))
    parts.append("### Provenance\n\n" + _provenance_rows(rec, session.get("adw_name"), local=local))
    parts.append("### Phase timeline\n\n" + _fmt_phase_list(phases))
    parts.append("### Review verdicts\n\n" + _fmt_reviews(trace.get("envelopes") or []))
    parts.append("### Commits (BASE..HEAD)\n\n" + _fmt_commits(commits))
    parts.append("### Cost\n\n" + _fmt_cost(session))
    parts.append("### Outcome reason (verbatim)\n\n```text\n"
                 + _outcome_reason(outcome, note, trace) + "\n```")
    parts.append("### Harvest status\n\n" + _harvest_status(rec.get("run_id"), rec, commits,
                                                             local=local))
    parts.append("### Trace source\n\n`" + str(trace.get("source") or "none") + "`")
    if rec.get("prev_issue_number"):
        parts.append(f"### Follow-up\n\nFollow-up to #{rec.get('prev_issue_number')}")
    return "\n\n".join(parts)


# ── verbs ───────────────────────────────────────────────────────────────────
def _issues_disabled() -> bool:
    return os.environ.get("SSSF_ISSUES", "1") == "0"


def cmd_open(args: argparse.Namespace) -> int:
    if _issues_disabled():
        print("issues: disabled (SSSF_ISSUES=0) — skipping issue tracking")
        return 0
    rec = get_record(args.run_id)
    if rec is None:
        return 1
    local = _is_local(rec, getattr(args, "local", False))
    try:
        repo, _, _ = _app_config()
    except RuntimeError as e:
        die(str(e))
    if not repo:
        print("issues: vendored mode — roster has no app.repo; skipping issue tracking")
        return 0
    if not gh_auth_ok():
        warn("gh is not authenticated on this host — skipping issue tracking")
        return 0

    ensure_labels(repo)

    # Follow-up detection: the record already references an issue that was closed
    # as failed (sssf:failed / NOT_PLANNED). This session re-runs that record.
    prev = None
    prev_num = rec.get("issue_number")
    if prev_num:
        info = _issue_info(repo, int(prev_num))
        if info and str(info.get("state", "")).upper() == "CLOSED" \
                and "sssf:failed" in _label_names(info):
            prev = int(prev_num)

    instruction = args.instruction or ""
    title = " ".join(instruction.split()) or f"SSSF session {args.run_id}"
    if len(title) > 200:
        title = title[:199].rstrip() + "…"
    body = redact(_open_body(rec, instruction, args.chain, prev, local=local))
    argv = ["issue", "create", "--repo", repo, "--title", title, "--body", body,
            "--label", "sssf:running"]
    if local:
        argv += ["--label", "sssf:local"]
    if prev:
        argv += ["--label", "sssf:follow-up"]
    r = gh(argv)
    if r.returncode != 0:
        warn(f"gh issue create failed: {r.stderr.strip()[:300]}")
        return 0
    url = (r.stdout or "").strip().splitlines()
    url = url[-1].strip() if url else ""
    m = re.search(r"/issues/(\d+)", url)
    fields: dict = {"issue_url": url, "issue_state": "open"}
    if m:
        fields["issue_number"] = int(m.group(1))
    if prev:
        fields["prev_issue_number"] = prev
    set_record(args.run_id, **fields)
    print(f"issues: opened {url}" + (f" (follow-up to #{prev})" if prev else ""))
    return 0


def do_update(run_id: str, milestone: str, db: str | None = None,
              rec: dict | None = None) -> bool:
    rec = rec if rec is not None else get_record(run_id)
    repo = _repo_from_record(rec)
    num = (rec or {}).get("issue_number")
    if not repo or not num:
        return False
    marker = f"<!-- sssf:milestone:{milestone} -->"
    info = _issue_info(repo, int(num), comments=True)
    if info is None:
        warn(f"could not read issue #{num}")
        return False
    for c in (info.get("comments") or []):
        if marker in (c.get("body") or ""):
            return False  # already posted
    trace = _trace(run_id, db=db, record=rec)
    body = redact(_milestone_body(milestone, trace))
    r = gh(["issue", "comment", str(num), "--repo", repo, "--body", body])
    if r.returncode != 0:
        warn(f"milestone comment failed: {r.stderr.strip()[:200]}")
        return False
    print(f"issues: milestone '{milestone}' -> #{num}")
    return True


def cmd_update(args: argparse.Namespace) -> int:
    if _issues_disabled():
        return 0
    if do_update(args.run_id, args.milestone, db=args.db):
        return 0
    return 0


def _sync_state_from_labels(rec: dict, info: dict) -> str:
    labels = _label_names(info)
    for state in ("accepted", "failed", "cancelled"):
        if f"sssf:{state}" in labels:
            return state
    return "open"


def close_issue(run_id: str, outcome: str, note: str | None = None,
                db: str | None = None, rec: dict | None = None,
                local: bool = False) -> bool:
    """Append the final comment, flip labels, close the issue. Idempotent."""
    rec = rec if rec is not None else get_record(run_id)
    local = _is_local(rec, local)
    repo = _repo_from_record(rec)
    num = (rec or {}).get("issue_number")
    if not repo or not num:
        print(f"issues: no issue recorded for {run_id} — nothing to close")
        return False
    info = _issue_info(repo, int(num))
    if info is None:
        warn(f"could not read issue #{num} — leaving it for sync-issues")
        return False
    if str(info.get("state", "")).upper() == "CLOSED":
        warn(f"issue #{num} is already closed — nothing to do")
        if rec is not None:
            set_record(run_id, issue_state=_sync_state_from_labels(rec, info))
        return True

    trace = _trace(run_id, db=db, record=rec)
    body = redact(_final_comment(outcome, note, rec, trace, local=local))
    r = gh(["issue", "comment", str(num), "--repo", repo, "--body", body])
    if r.returncode != 0:
        warn(f"final comment failed: {r.stderr.strip()[:200]}")
        return False
    gh(["issue", "edit", str(num), "--repo", repo, "--remove-label", "sssf:running"])
    gh(["issue", "edit", str(num), "--repo", repo, "--add-label", f"sssf:{outcome}"])
    reason = "completed" if outcome == "accepted" else "not planned"
    r = gh(["issue", "close", str(num), "--repo", repo, "--reason", reason])
    if r.returncode != 0:
        warn(f"gh issue close failed: {r.stderr.strip()[:200]}")
        return False
    set_record(run_id, issue_state=outcome)
    print(f"issues: issue #{num} closed as {outcome}")
    return True


def cmd_close(args: argparse.Namespace) -> int:
    if _issues_disabled():
        print("issues: disabled (SSSF_ISSUES=0) — not closing anything")
        return 0
    close_issue(args.run_id, args.outcome, note=args.note, db=args.db,
                local=getattr(args, "local", False))
    return 0


def _has_verification_phase(phases: list[dict]) -> bool:
    for p in phases:
        if VERIFY_PHASE.match(str(p.get("name") or "")) \
                and str(p.get("status")).lower() == "success":
            return True
    return False


def cmd_watch(args: argparse.Namespace) -> int:
    rec = get_record(args.run_id)
    if rec is None or not rec.get("issue_number"):
        return 0
    deadline = time.monotonic() + WATCH_MAX_SECONDS
    milestone_done = False
    misses = 0
    while time.monotonic() < deadline:
        # If the issue has already been closed out-of-band (teardown cancelled it,
        # or sync-issues reconciled it), stop: the record's state is the authority
        # and continuing would only re-close an issue it no longer owns. Checked
        # against the snapshot's issue_number so a follow-up that replaced the
        # record's issue does not silence this watcher.
        fresh = get_record(args.run_id)
        if fresh and fresh.get("issue_number") == rec.get("issue_number") \
                and str(fresh.get("issue_state") or "").lower() in (
                    "accepted", "failed", "cancelled"):
            return 0
        try:
            trace = _trace(args.run_id, since=args.since, record=rec)
            misses = 0
        except Exception as e:
            misses += 1
            warn(f"watch {args.run_id}: trace read failed ({misses}): {e}")
            if misses >= 20:
                warn("watch: too many consecutive failures — teardown/sync-issues "
                     "are the backstops")
                return 0
            time.sleep(WATCH_INTERVAL)
            continue

        session = trace.get("session")
        if not session:
            time.sleep(WATCH_INTERVAL)
            continue
        if not milestone_done and _has_verification_phase(trace.get("phases") or []):
            do_update(args.run_id, "review", rec=rec)
            milestone_done = True
        status = str(session.get("status") or "").lower()
        if status == "success":
            close_issue(args.run_id, "accepted", rec=rec,
                        local=getattr(args, "local", False))
            return 0
        if status in ("fail", "failed", "error"):
            close_issue(args.run_id, "failed", rec=rec,
                        local=getattr(args, "local", False))
            return 0
        time.sleep(WATCH_INTERVAL)
    warn(f"watch {args.run_id}: timed out after {WATCH_MAX_SECONDS}s")
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    if _issues_disabled():
        print("sync-issues: disabled (SSSF_ISSUES=0)")
        return 0
    records = run_record.list_runs()
    reconciled = running = skipped = 0
    for rec in records:
        rid = rec.get("run_id") or "?"
        repo = _repo_from_record(rec)
        num = rec.get("issue_number")
        if not repo or not num:
            skipped += 1
            continue
        info = _issue_info(repo, int(num))
        if info is None:
            print(f"   {rid}: issue #{num} unreadable — skipping")
            skipped += 1
            continue
        if str(info.get("state", "")).upper() == "CLOSED":
            set_record(rid, issue_state=_sync_state_from_labels(rec, info))
            skipped += 1
            continue
        try:
            trace = _trace(rid, record=rec)
        except Exception as e:
            print(f"   {rid}: no trace available ({e}) — skipping")
            skipped += 1
            continue
        session = trace.get("session")
        status = str((session or {}).get("status") or "").lower()
        if status == "success":
            if close_issue(rid, "accepted", rec=rec):
                reconciled += 1
        elif status in ("fail", "failed", "error"):
            if close_issue(rid, "failed", rec=rec):
                reconciled += 1
        elif rec.get("closed_at"):
            if close_issue(rid, "cancelled",
                           note="reconciled by sync-issues (run was torn down)",
                           rec=rec):
                reconciled += 1
        else:
            print(f"   {rid}: session still running — leaving alone")
            running += 1
    print(f"sync-issues: {reconciled} reconciled, {running} still running, "
          f"{skipped} skipped")
    return 0


def _harvest_comment(args: argparse.Namespace, rec: dict) -> str:
    """The body of a harvest comment for one of the four integration outcomes."""
    base_ref = args.base_ref or rec.get("base_ref") or "main"
    sha = args.merge_sha or "(unknown)"
    local = _local_path_quiet() or "<app.local_path>"
    run_id = args.run_id
    if args.result == "merged":
        return (f"## Harvest — merged\n\n"
                f"Merged into `{base_ref}` as `{sha}`.\n\n"
                "The merge is in the app's local clone only — **push stays human**.")
    if args.result == "bundle-only":
        return ("## Harvest — bundle-only\n\n"
                "bundle-only — awaiting integration decision.")
    if args.result == "unmerged":
        conflicts = " ".join(str(c) for c in (args.conflicts or "").split() if c)
        files = "\n".join(f"- `{f}`" for f in conflicts.split()) or "_(none reported)_"
        return (f"## Harvest — conflict (not merged)\n\n"
                f"Merging the run branch into `{base_ref}` hit conflicts. The merge "
                "was **aborted** — the local clone is clean and the run branch is "
                "fetched. Run marked `harvested-unmerged`.\n\n"
                f"**Conflicting files:**\n\n{files}\n\n"
                "**Resolve manually** (nothing is pushed):\n\n"
                "```bash\n"
                f"git -C {local} checkout {base_ref}\n"
                f"git -C {local} merge refs/harvest/{run_id}\n"
                "# resolve the conflicts, then:\n"
                f"git -C {local} add <files> && git -C {local} commit\n"
                "```")
    # broke-build
    failing = " ".join(str(c) for c in (args.failing_checks or "").split() if c)
    failing_line = ("**Failing checks:** " + ", ".join(f"`{c}`" for c in failing.split())
                    if failing else "**Failing checks:** see the harvest run output")
    return (f"## Harvest — merge broke the build\n\n"
            f"The merge into `{base_ref}` was textually clean (merge sha `{sha}`), "
            "but the post-merge checks **FAILED**. The merge was reverted locally; "
            "the run branch stays fetched.\n\n"
            f"{failing_line}\n\n"
            "Reopening this issue until the merge is resolved.")


def cmd_harvest(args: argparse.Namespace) -> int:
    if _issues_disabled():
        print("issues: disabled (SSSF_ISSUES=0) — not recording the harvest")
        return 0
    rec = get_record(args.run_id)
    if rec is None:
        return 0
    repo = _repo_from_record(rec)
    num = rec.get("issue_number")
    if not repo or not num:
        warn(f"no issue recorded for {args.run_id} — nothing to comment")
        return 0
    if not gh_auth_ok():
        warn("gh is not authenticated on this host — skipping harvest comment")
        return 0
    ensure_labels(repo)
    body = redact(_harvest_comment(args, rec))
    r = gh(["issue", "comment", str(num), "--repo", repo, "--body", body])
    if r.returncode != 0:
        warn(f"harvest comment failed: {r.stderr.strip()[:200]}")
        return 0
    print(f"issues: harvest '{args.result}' -> #{num}")
    if args.result == "broke-build":
        # A textual merge that broke the checks is NOT done: reopen the issue and
        # label it until a human resolves it. The tracker never removes the label.
        gh(["issue", "reopen", str(num), "--repo", repo])
        gh(["issue", "edit", str(num), "--repo", repo,
            "--add-label", "sssf:merged-broken"])
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    o = sub.add_parser("open", help="create the issue and record its url/number")
    o.add_argument("run_id")
    o.add_argument("--instruction", required=True)
    o.add_argument("--chain", default=None)
    o.add_argument("--local", action="store_true",
                   help="LOCAL mode: label sssf:local, omit VM fields")
    o.set_defaults(func=cmd_open)

    u = sub.add_parser("update", help="append a milestone comment")
    u.add_argument("run_id")
    u.add_argument("--milestone", required=True)
    u.add_argument("--db", default=None)
    u.set_defaults(func=cmd_update)

    c = sub.add_parser("close", help="final comment + state label + close")
    c.add_argument("run_id")
    c.add_argument("--outcome", required=True,
                   choices=["accepted", "failed", "cancelled"])
    c.add_argument("--db", default=None)
    c.add_argument("--note", default=None)
    c.add_argument("--local", action="store_true",
                   help="LOCAL mode: read the host trace db, no VM fields")
    c.set_defaults(func=cmd_close)

    w = sub.add_parser("watch", help="host-side watcher: milestone + close")
    w.add_argument("run_id")
    w.add_argument("--since", required=True)
    w.add_argument("--local", action="store_true",
                   help="LOCAL mode: read the host trace db, no VM fields")
    w.set_defaults(func=cmd_watch)

    s = sub.add_parser("sync", help="reconcile issues left open by a dead watcher")
    s.set_defaults(func=cmd_sync)

    h = sub.add_parser("harvest", help="record a harvest outcome on the run's issue")
    h.add_argument("run_id")
    h.add_argument("--result", required=True,
                   choices=["merged", "unmerged", "broke-build", "bundle-only"])
    h.add_argument("--merge-sha", default=None)
    h.add_argument("--base-ref", default=None)
    h.add_argument("--conflicts", default=None,
                   help="space-separated conflicting files (unmerged)")
    h.add_argument("--failing-checks", default=None,
                   help="space-separated failing check names (broke-build)")
    h.set_defaults(func=cmd_harvest)
    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except Exception as e:  # every tracker failure is best-effort
        warn(f"{args.command} failed: {e}")
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
