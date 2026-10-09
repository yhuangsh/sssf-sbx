#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""Run an app manifest's `checks:` against a HOST-SIDE tree.

This is the post-merge verification step of `just sbx manage harvest`: after a
run's commits are merged into the app's local clone, the same deterministic
checks the SDLC quality phase would run inside the sandbox are re-run against the
merged tree — from the host, where there is no VM to reach. It is deliberately a
small, separate script: it mirrors `adws/adw_modules/quality.py`'s check-shape
parsing rather than importing the module (which drags in the whole ADW runtime),
so the two stay in sync by convention, not by coupling.

Usage:
    run_manifest_checks.py <app_dir> [--manifest sssf.app.yaml]

Exit 0 when every EXECUTED check passed (a skip is not a failure). Exit 1 with
the failing check names otherwise, so harvest can revert its merge.

A check whose argv[0] is not on PATH is SKIPPED with a named line — the host may
not carry the app's runtime (bun/node/…), and a missing runtime must not read as
a broken build. Logs go under a temp dir (never into the app tree, which has to
stay clean and the kernel repo, which must not be touched).
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_MANIFEST = "sssf.app.yaml"
DEFAULT_TIMEOUT = 120


def _load_checks(app_dir: Path, manifest_name: str) -> list[dict]:
    """Resolve the manifest's `checks:` into {name, argv, timeout_seconds}.

    `checks:` has TWO documented shapes and BOTH must load (same as
    quality._load_checks): a MAP of name -> argv, and a LIST of
    {name, area, operation, argv, timeout_seconds}. A map entry has nowhere to
    state a timeout, so it takes the same default a half-filled list entry does.
    """
    import yaml

    manifest = app_dir / manifest_name
    if not manifest.is_file():
        return []
    data = yaml.safe_load(manifest.read_text()) or {}
    entries = data.get("checks") or []
    if isinstance(entries, dict):
        entries = [{"name": name, "argv": argv} for name, argv in entries.items()]
    checks = []
    for entry in entries:
        argv = [str(a) for a in (entry.get("argv") or [])]
        if not argv:
            continue
        checks.append({
            "name": str(entry.get("name") or "check"),
            "argv": argv,
            "timeout_seconds": entry.get("timeout_seconds", DEFAULT_TIMEOUT),
        })
    return checks


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Run an app manifest's checks host-side")
    p.add_argument("app_dir", help="directory holding the manifest (the merged tree)")
    p.add_argument("--manifest", default=DEFAULT_MANIFEST)
    args = p.parse_args(argv)

    app_dir = Path(args.app_dir).expanduser().resolve()
    if not app_dir.is_dir():
        print(f"SKIP: no app dir at {app_dir}", file=sys.stderr)
        return 0

    checks = _load_checks(app_dir, args.manifest)
    if not checks:
        print(f"SKIP: {args.manifest} absent or declares no checks — nothing to verify")
        print("run_manifest_checks: PASS executed=0 skipped=0 failed=0")
        return 0

    # Logs live OUTSIDE the app tree: the merged clone has to stay clean, and a
    # .harvest-checks/ dir inside it would dirty it for the next harvest.
    log_dir = Path(tempfile.mkdtemp(prefix="harvest-checks-"))
    executed = skipped = failed = 0
    failures: list[str] = []

    for check in checks:
        name = check["name"]
        argv = list(check["argv"])
        # `{outdir}` is quality.py's artifact-dir token. Nothing here needs an
        # artifact bundle; give it a real temp dir so the token is not passed
        # through literally, and say so in the log.
        outdir = tempfile.mkdtemp(prefix=f"harvest-{name}-out-")
        argv = [a.replace("{outdir}", outdir) for a in argv]

        runtime = argv[0]
        if shutil.which(runtime) is None:
            print(f"SKIP {name}: runtime '{runtime}' not available host-side")
            skipped += 1
            continue

        log_path = log_dir / f"{name}.log"
        started = time.monotonic()
        try:
            completed = subprocess.run(argv, cwd=app_dir, capture_output=True,
                                       text=True, timeout=check["timeout_seconds"])
            returncode = completed.returncode
            stdout, stderr = completed.stdout, completed.stderr
        except subprocess.TimeoutExpired as e:
            returncode = 124
            stdout = e.stdout or ""
            stderr = (e.stderr or "") + f"\nTimed out after {check['timeout_seconds']}s."
        except OSError as e:
            returncode = 127
            stdout, stderr = "", str(e)
        duration = time.monotonic() - started
        log_path.write_text(
            f"$ {' '.join(argv)}\nexit: {returncode}\nduration_seconds: {duration:.3f}\n"
            f"\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}\n")
        executed += 1
        if returncode == 0:
            print(f"PASS {name} ({duration:.2f}s)")
        else:
            failed += 1
            failures.append(name)
            print(f"FAIL {name} (exit {returncode}) — log: {log_path}")

    status = "FAIL" if failures else "PASS"
    print(f"run_manifest_checks: {status} executed={executed} skipped={skipped} failed={failed}")
    if failures:
        print(f"failing checks: {', '.join(failures)}", file=sys.stderr)
        print(f"logs: {log_dir}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
