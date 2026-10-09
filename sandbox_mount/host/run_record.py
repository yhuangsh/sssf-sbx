#!/usr/bin/env python3
"""The run record — the only state shared across the six sandbox phases.

Each phase (create, fill, setup, execute, observe, teardown) is a separate
process, so nothing survives between them except what is on disk. Teardown has
no other way to learn which VM to destroy and which commits to harvest: lose the
record and the run cannot be cleaned up. One JSON file per run, keyed by run_id,
under the per-app STATE ROOT (gitignored per app):

    local mode / target mode WITH app.local_path -> <local_path>/sssf/runs/
    target mode WITHOUT local_path               -> ~/.sssf/apps/<app-key>/runs/
    vendored mode (kernel-self, no app.repo)      -> .sandbox/runs/ (unchanged)

Legacy `.sandbox/runs/` records stay READABLE (reads search the new location
first, then legacy), so pre-change runs keep resolving until `migrate` moves
them. Kernel-self development is deliberately unchanged: those artifacts belong
to the kernel project.

Usage:
    run_record.py create    <run-id>
    run_record.py get       <run-id> [field]
    run_record.py set       <run-id> key=value [key=value ...]
    run_record.py close     <run-id>
    run_record.py list
    run_record.py path      <run-id>
    run_record.py new-id    <task>
    run_record.py state-root        # resolved state root (empty line in vendored mode)
    run_record.py runs-dir          # effective runs directory
    run_record.py migrate           # move legacy .sandbox/runs items into the state root

`get <run-id> <field>` prints the bare value so shell can capture it:
    RUN_VM=$(sandbox_mount/host/run_record.py get my-run vm_name)

Stdlib only, on purpose: this runs on the host before any toolchain exists and
must never be the reason a teardown cannot start.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

# sandbox_mount/host/run_record.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[2]
# Legacy/kernel location. Still the vendored-mode home and the transition source.
LEGACY_RUNS_DIR = REPO_ROOT / ".sandbox" / "runs"
# Sandbox-only target mode (app.repo, no app.local_path): a per-app root in $HOME.
HOME_STATE_ROOT = Path.home() / ".sssf" / "apps"

# The closed schema. Every field is referenced by name somewhere in the six
# phases, so a typo in a `set` is a silent data loss bug -- reject unknown keys
# rather than write them.
FIELDS = (
    "run_id",
    "vm_name",
    "tag",
    "https_url",
    "session_id",
    "commit_sha",
    "factory_sha",
    "ports",
    "pid",
    "created_at",
    "closed_at",
    # ── GitHub-issue tracking (sandbox_mount/host/issue_tracker.py) ─────────
    # The tracker's view of this run's issue in the roster's app.repo. Added by
    # the sanctioned field-extension path (same as `ports`): the schema stays
    # closed, unknown keys are still rejected, and these four are the only
    # fields the tracker may write. `set`/`get`/`close`/`list` are unchanged.
    "issue_url",          # https://github.com/<owner>/<repo>/issues/<n>
    "issue_number",       # int — the issue number in that repo
    "issue_state",        # open | accepted | failed | cancelled (tracker's view)
    "prev_issue_number",  # int — the issue this run's previous execute opened
    # ── harvest integration modes (just/sandbox/manage/harvest.just) ────────
    # The sanctioned field-extension path again (same as `ports` and the issue
    # block above): the schema stays closed, unknown keys are still rejected.
    # `base_ref`/`base_sha` are the merge anchor FILL records in target mode;
    # `merge_mode` is the run's default (merge), `harvest_state`/`merge_sha` are
    # written by HARVEST once it lands (or declines to land) the commits.
    "base_ref",           # branch the run started from (roster app.ref, default main)
    "base_sha",           # the sha base_ref pointed at when the run filled
    "merge_mode",         # merge | bundle-only — the run's default integration mode
    "harvest_state",      # null | bundle-only | merged | harvested-unmerged | merge-broke-build
    "merge_sha",          # merge commit (or fast-forward tip) in the local clone
)

# Identity, not state. run_id is also the filename, so rewriting it would leave
# the record answering to a name that is not its own.
IMMUTABLE = ("run_id", "created_at")

# CLI values arrive as strings. Per-field coercion instead of "try JSON first",
# because a commit_sha of 5734129 is a string that happens to parse as a number.
_COERCE = {"ports": "json", "pid": "int",
           "issue_number": "int", "prev_issue_number": "int"}


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def app_key(repo_url: str) -> str:
    """Sanitized basename of an app repo URL, e.g.
    https://github.com/yhuangsh/hello-server.git -> hello-server.

    basename minus `.git`, lowercased, every run of non [a-z0-9] collapsed to a
    single `-`. Empty/odd input still yields a usable key.
    """
    base = (repo_url or "").rstrip("/").rsplit("/", 1)[-1]
    if base.endswith(".git"):
        base = base[:-4]
    key = re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")
    return key or "app"


def _roster_app(roster_path: Path | str | None) -> tuple[str | None, str | None]:
    """(app.repo, app.local_path) from the roster's `app:` block.

    A line scan, NOT yaml: this module stays stdlib-only and runs before any
    toolchain exists. Same two-space convention the just recipes parse with awk:
    the block starts at a column-0 `app:` and ends at the next column-0 key;
    blank lines and `#` comments are ignored, so a COMMENTED-OUT `local_path:`
    does not count. Comment tails after a value are dropped (only the value
    token is read).
    """
    repo = local_path = None
    if not roster_path:
        return None, None
    try:
        text = Path(roster_path).read_text()
    except OSError:
        return None, None
    in_app = False
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw[0] not in (" ", "\t"):
            in_app = raw.split("#", 1)[0].strip() == "app:"
            continue
        if not in_app:
            continue
        m = re.match(r"[ \t]+(repo|local_path):[ \t]*(\S+)", raw)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        if key == "repo" and repo is None:
            repo = value
        elif key == "local_path" and local_path is None:
            local_path = value
    return repo, local_path


def resolve_state_root(roster_path: Path | str | None) -> Path | None:
    """The per-run state root for a roster path, or None = vendored/kernel mode.

    (a) app.local_path set  -> <local_path>/sssf
    (b) app.repo set        -> ~/.sssf/apps/<app-key>
    (c) neither             -> None (kernel's .sandbox/runs + adws/adw_data)
    `~` in local_path expands. cwd-independent: the path is used as written.
    """
    repo, local_path = _roster_app(roster_path)
    if local_path:
        clone = Path(os.path.expanduser(local_path))
        if not clone.is_absolute():
            # Same convention as `just local mount`: a relative local_path is
            # relative to the kernel root, so resolution is cwd-independent.
            clone = REPO_ROOT / clone
        return clone / "sssf"
    if repo:
        return HOME_STATE_ROOT / app_key(repo)
    return None


def state_root() -> Path | None:
    """The active roster's ($SSSF_CONFIG) state root, or None.

    None when SSSF_CONFIG is unset/unparseable or resolves to vendored mode —
    callers then fall back to legacy `.sandbox/runs/`, so `run_record.py list`
    in `doctor` keeps working without a roster.
    """
    return resolve_state_root(os.environ.get("SSSF_CONFIG"))


def runs_dir() -> Path:
    """The effective runs directory: <state_root>/runs, or legacy when vendored."""
    root = state_root()
    return (root / "runs") if root else LEGACY_RUNS_DIR


def resolve_record_path(run_id: str) -> Path:
    """Where a record is READ.

    New location first, then legacy (transition compatibility), else the new
    location so a FileNotFoundError names the canonical place. A record that
    exists ONLY in legacy is therefore read and updated IN PLACE pre-migration.
    """
    new = runs_dir() / f"{run_id}.json"
    if new.exists():
        return new
    legacy = LEGACY_RUNS_DIR / f"{run_id}.json"
    if legacy.exists():
        return legacy
    return new


def path(run_id: str) -> Path:
    """Where this run's record lives (canonical, used by the `path` CLI).
    Does not create anything."""
    return runs_dir() / f"{run_id}.json"


def new_run_id(task: str) -> str:
    """A run id that has never existed before: <task>-<YYYYMMDD>-<6 hex>.

    Generated, never supplied by the caller. The run id becomes the VM name and
    the VM name becomes a public URL, so a collision is not a local annoyance --
    it is two runs fighting over one hostname. The task is slugified because
    that hostname has to survive DNS.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", task.lower()).strip("-") or "run"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    return f"{slug}-{stamp}-{secrets.token_hex(3)}"


def create(run_id: str) -> dict:
    """Seed the record with run_id + created_at. Refuses to clobber."""
    record = {f: None for f in FIELDS}
    record["run_id"] = run_id
    record["created_at"] = _now()
    # Seed the integration default so old and new records read alike: MERGE is
    # the common case (parallel-orthogonal features on one repo); bundle-only is
    # the special case (competing fan-out arms) and is opted into per run with
    # `harvest --no-merge`. FILL refines this to bundle-only in vendored mode.
    record["merge_mode"] = "merge"

    target_dir = runs_dir()
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{run_id}.json"
    # O_EXCL, not `if target.exists()`: overwriting a live record orphans that
    # run's teardown handle, and the check-then-write window is exactly when a
    # retrying phase would land.
    try:
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise FileExistsError(f"run record already exists: {target}") from None
    with os.fdopen(fd, "w") as fh:
        json.dump(record, fh, indent=2)
        fh.write("\n")
    return record


def get(run_id: str, field: str | None = None):
    """The whole record, or one field."""
    target = resolve_record_path(run_id)
    try:
        record = json.loads(target.read_text())
    except FileNotFoundError:
        raise FileNotFoundError(f"no run record: {target}") from None
    if field is None:
        return record
    if field not in FIELDS:
        raise ValueError(f"unknown field {field!r}; known: {', '.join(FIELDS)}")
    return record.get(field)


def set(run_id: str, **fields) -> dict:  # noqa: A001 - the verb the plan uses
    """Merge fields into the record. Unknown or immutable keys are rejected."""
    return _apply(run_id, fields)


def _apply(run_id: str, fields: dict) -> dict:
    """set() with the fields as a dict.

    The CLI cannot go through **fields: `set my-run run_id=x` would collide with
    the positional and die with a TypeError instead of the real complaint.
    """
    if not fields:
        raise ValueError("set requires at least one field")
    for key in fields:
        if key not in FIELDS:
            raise ValueError(f"unknown field {key!r}; known: {', '.join(FIELDS)}")
        if key in IMMUTABLE:
            raise ValueError(f"{key} is set once at create and cannot be changed")
    record = get(run_id)
    record.update(fields)
    _write(run_id, record)
    return record


def close(run_id: str) -> dict:
    """Mark the run torn down. Non-null closed_at means teardown finished.

    Idempotent, and the first close wins: teardown is retryable and the moment
    that matters is when the run actually died.
    """
    record = get(run_id)
    if record.get("closed_at") is None:
        record["closed_at"] = _now()
        _write(run_id, record)
    return record


def _read_records(directory: Path) -> dict[str, dict]:
    """Every record in `directory`, keyed by run_id. Loud on a malformed one."""
    out: dict[str, dict] = {}
    if not directory.is_dir():
        return out
    for f in sorted(directory.glob("*.json")):
        try:
            rec = json.loads(f.read_text())
        except (OSError, ValueError) as e:
            # Loud, not skipped. A record quietly dropped for being malformed
            # hides a run's VM from teardown.
            raise ValueError(f"unreadable run record {f}: {e}") from None
        out[rec.get("run_id") or f.stem] = rec
    return out


def list_runs() -> list[dict]:
    """Every record, newest first. New location wins over a legacy twin."""
    records = _read_records(LEGACY_RUNS_DIR)
    records.update(_read_records(runs_dir()))   # new location wins on dedupe
    rows = list(records.values())
    rows.sort(key=lambda r: (r.get("created_at") or "", r.get("run_id") or ""), reverse=True)
    return rows


def _write(run_id: str, record: dict) -> None:
    target = resolve_record_path(run_id)
    tmp = target.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n")
    os.replace(tmp, target)  # atomic: a crash mid-write leaves the old record, not half of one


def _coerce(key: str, raw: str):
    if raw == "null":
        return None
    kind = _COERCE.get(key)
    if kind == "int":
        return int(raw)
    if kind == "float":
        return float(raw)
    if kind == "json":
        return json.loads(raw)
    return raw


_MIGRATE_SUFFIXES = ("-artifacts", ".bundle", ".watcher.log")


def _safe_move(src: Path, dst: Path) -> None:
    """Move src to dst, NON-DESTRUCTIVELY: a partial destination is cleaned up
    and the source left untouched if anything fails (shutil.move only unlinks
    the source after a successful copy, so a half-copy never costs the source)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        raise FileExistsError(f"destination exists: {dst}")
    tmp = dst.with_name(dst.name + ".migrating")
    try:
        shutil.move(str(src), str(tmp))
        os.replace(tmp, dst)
    except Exception:
        if tmp.is_dir():
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            tmp.unlink(missing_ok=True)
        raise


def _move_record(src: Path, dst: Path) -> None:
    """Move a record JSON with write -> verify -> remove, so a failed move can
    never lose a record."""
    data = src.read_bytes()
    parsed = json.loads(data)          # raises before anything is written
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".migrating")
    tmp.write_bytes(data)
    back = json.loads(tmp.read_bytes())  # read-back verification
    if back != parsed:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"verification mismatch for {dst}")
    os.replace(tmp, dst)
    src.unlink()                        # only now is the source removed


def migrate() -> int:
    """Move every legacy .sandbox/runs item into the resolved state root.

    Idempotent (destination wins) and NON-DESTRUCTIVE on failure: a failed item
    leaves its source in place, the error is printed, and the run exits 1 after
    processing the rest. Refuses vendored/unresolved mode — there is no re-home
    target, and moving the kernel's own records into the kernel would be a no-op.
    """
    root = state_root()
    if root is None:
        print("run_record: migrate refuses vendored/unresolved mode — set SSSF_CONFIG "
              "to an app roster (app.repo or app.local_path)", file=sys.stderr)
        return 1
    dest = root / "runs"
    if not LEGACY_RUNS_DIR.is_dir():
        print("migrate: no legacy .sandbox/runs/ directory — nothing to migrate")
        return 0
    ids = sorted({p.stem for p in LEGACY_RUNS_DIR.glob("*.json")})
    moved = failures = 0
    for run_id in ids:
        items = [LEGACY_RUNS_DIR / f"{run_id}.json"]
        items += [LEGACY_RUNS_DIR / f"{run_id}{suffix}" for suffix in _MIGRATE_SUFFIXES]
        for src in items:
            if not src.exists():
                continue
            target = dest / src.name
            if target.exists():
                print(f"migrate: skip {src.name} (already at destination)")
                continue
            try:
                if src.name.endswith(".json"):
                    _move_record(src, target)
                else:
                    _safe_move(src, target)
            except Exception as e:
                failures += 1
                print(f"migrate: FAILED {src} -> {target}: {e}", file=sys.stderr)
                continue
            moved += 1
            print(f"migrate: {src} -> {target}")
    if failures:
        print(f"migrate: {moved} item(s) moved, {failures} FAILURE(s) — sources left intact",
              file=sys.stderr)
        return 1
    print(f"migrate: {moved} item(s) moved into {dest}")
    return 0


def _print(value) -> None:
    """Bare value for shell capture; JSON only for things shell cannot hold."""
    if value is None:
        print("")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    elif isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]

    if cmd == "list":
        print(json.dumps(list_runs(), indent=2))
        return 0

    if cmd == "new-id":
        if len(args) != 1:
            print("usage: run_record.py new-id <task>", file=sys.stderr)
            return 2
        print(new_run_id(args[0]))
        return 0

    if cmd == "state-root":
        _print(state_root())              # empty line for vendored/unresolved mode
        return 0

    if cmd == "runs-dir":
        print(runs_dir())
        return 0

    if cmd == "migrate":
        return migrate()

    if not args:
        print(f"usage: run_record.py {cmd} <run-id>", file=sys.stderr)
        return 2
    run_id, rest = args[0], args[1:]

    if cmd == "path":
        print(path(run_id))
        return 0
    if cmd == "create":
        create(run_id)
        print(path(run_id))
        return 0
    if cmd == "get":
        if len(rest) > 1:
            print("usage: run_record.py get <run-id> [field]", file=sys.stderr)
            return 2
        if rest:
            _print(get(run_id, rest[0]))
        else:
            print(json.dumps(get(run_id), indent=2))
        return 0
    if cmd == "set":
        fields = {}
        for pair in rest:
            if "=" not in pair:
                print(f"expected key=value, got {pair!r}", file=sys.stderr)
                return 2
            key, raw = pair.split("=", 1)
            fields[key] = _coerce(key, raw)
        _apply(run_id, fields)
        return 0
    if cmd == "close":
        close(run_id)
        return 0

    print(f"unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as e:
        print(f"run_record: {e}", file=sys.stderr)
        sys.exit(1)
