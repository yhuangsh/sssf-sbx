"""Deterministic quality checks, driven by the app's `sssf.app.yaml` manifest.

The check set is DATA, not code: each app declares its own commands and the
factory runs them. This module owns the mechanics — where an artifact lands, how
a failure is packed for the builder — and takes the naming, area, operation,
argv, and timeout from the manifest. For the vendored inkwell app the outcome is
identical to the old hardcoded blocks: the same commands against the same files,
the same six non-test checks in `run_inkwell_quality` plus the `tests` block.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import time
from pathlib import Path

import yaml

from .data_types import (EventRecord, QualityCheckResult, QualityCheckSpec, QualityResult,
                         VerifyOutput)
from .utils import now_iso, operator_env

# How much of a failing command's output rides back inside the envelope. Enough
# for a builder to act on without opening the artifact; bounded so a runaway
# stack trace can't swamp the next agent's context.
TAIL_CHARS = 4_000


# Invoked by bare name, exactly as the operator would type it: an ADW inherits
# their environment, so `bun` resolves off PATH here for the same reason it does
# in their shell. Resolving it to an absolute path instead would hard-code one
# machine's layout into the trace and into the artifact logs.
#
# BUN_PATH remains the escape hatch for an environment that does NOT put bun on
# PATH — a container, or a cron with a stripped PATH. A genuinely missing binary
# is not something to pre-empt: _run's OSError branch already records it as
# exit 127 with the real error text.
BUN = os.environ.get("BUN_PATH", "").strip() or "bun"

# Phase 0 compat defaults, mirroring AppConfig in data_types.py. Used when a run
# predates the `app:` block.
DEFAULT_APP_PATH = "apps/inkwell"
DEFAULT_APP_MANIFEST = "sssf.app.yaml"


def _check_dir(run, name: str) -> Path:
    seq = run.phases[-1].seq if run.phases else 0
    # Anchor at the repo root. Manifest checks run with cwd = the app dir, so a
    # relative artifact path (or a relative `{outdir}` handed to a build) would
    # resolve THERE and pollute the app tree — gate A would then see it.
    root = run.context_handoff_dir
    if not root.is_absolute():
        root = run.repo_root / root
    path = root / "quality" / f"{seq:02d}_{name}"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _app_dir(run) -> Path:
    """Where the app under test lives: the roster's `app.path` under repo root."""
    app = getattr(run.cfg, "app", None)
    path = getattr(app, "path", None) or DEFAULT_APP_PATH
    return run.repo_root / path


def _load_checks(run) -> list[QualityCheckSpec]:
    """Resolve the manifest's `checks:` into ready-to-run specs.

    argv paths are relative to the app dir (checks run with cwd = the app dir).
    The literal `{outdir}` token is replaced with that check's absolute artifact
    bundle dir, so builds write outside the app tree and gate A stays clean. A
    manifest that is absent or declares no checks yields no checks: the SDLC
    still runs, it just skips the deterministic quality phase.
    """
    app = getattr(run.cfg, "app", None)
    manifest_name = getattr(app, "manifest", None) or DEFAULT_APP_MANIFEST
    manifest_path = _app_dir(run) / manifest_name
    if not manifest_path.is_file():
        return []
    manifest = yaml.safe_load(manifest_path.read_text()) or {}
    specs: list[QualityCheckSpec] = []
    # `checks:` has TWO documented shapes and BOTH must load:
    #   MAP  — keys are check names, values are argv lists (spec 6159cbd5 Decision 2)
    #   LIST — {name, area, operation, argv, timeout_seconds} mappings (inkwell's)
    # A map entry has nowhere to state area/operation/timeout, so it takes the same
    # defaults a half-filled list entry takes: backend / build / 120 s.
    entries = manifest.get("checks") or []
    if isinstance(entries, dict):
        entries = [{"name": name, "argv": argv} for name, argv in entries.items()]
    for entry in entries:
        name = entry["name"]
        outdir = str(_check_dir(run, name) / "bundle")
        argv = [str(arg).replace("{outdir}", outdir) for arg in entry["argv"]]
        # Preserve the BUN escape hatch: a manifest names `bun`, the module
        # resolves it (BUN_PATH wins) exactly as the old hardcoded blocks did.
        if argv and argv[0] == "bun":
            argv[0] = BUN
        specs.append(QualityCheckSpec(
            name=name,
            area=entry.get("area", "backend"),
            operation=entry.get("operation", "build"),
            argv=argv,
            timeout_seconds=entry.get("timeout_seconds", 120),
        ))
    return specs


def _run(spec: QualityCheckSpec, run, cwd: Path | None = None) -> QualityCheckResult:
    phase = run.phases[-1]
    output_dir = _check_dir(run, spec.name)
    output_artifact = output_dir / "command.log"
    command = shlex.join(spec.argv)
    env = operator_env()             # the engineer's own shell environment

    run.console.note(f"quality {spec.name}: {command}")
    started_at = now_iso()
    clock = time.monotonic()
    stdout = ""
    stderr = ""
    try:
        completed = subprocess.run(
            spec.argv,
            cwd=cwd or run.repo_root,   # app dir for manifest checks; repo root otherwise
            env=env,
            capture_output=True,
            text=True,
            timeout=spec.timeout_seconds,
        )
        returncode = completed.returncode
        stdout = completed.stdout
        stderr = completed.stderr
    except subprocess.TimeoutExpired as error:
        returncode = 124
        stdout = error.stdout or ""
        stderr = (error.stderr or "") + f"\nTimed out after {spec.timeout_seconds}s."
    except OSError as error:
        returncode = 127
        stderr = str(error)

    duration = time.monotonic() - clock
    output_artifact.write_text(
        f"$ {command}\nexit: {returncode}\nduration_seconds: {duration:.3f}\n"
        f"\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}\n"
    )
    passed = returncode == 0
    run.tracer.event(EventRecord(
        adw_id=run.adw_id,
        phase_id=phase.phase_id,
        type="tool_call",
        name=f"quality:{spec.name}",
        payload={
            "area": spec.area,
            "operation": spec.operation,
            "command": command,
            "returncode": returncode,
            "passed": passed,
            "output_artifact": str(output_artifact),
        },
        started_at=started_at,
        ended_at=now_iso(),
    ))
    run.console.note(
        f"quality {spec.name}: {'passed' if passed else 'failed'} "
        f"(exit {returncode}, {duration:.1f}s)"
    )
    return QualityCheckResult(
        name=spec.name,
        area=spec.area,
        operation=spec.operation,
        command=command,
        returncode=returncode,
        passed=passed,
        duration_seconds=duration,
        output_artifact=str(output_artifact),
        output_tail=(stdout + stderr)[-TAIL_CHARS:],
    )


def _run_checks(run, checks: list[QualityCheckSpec]) -> QualityResult:
    """Run the given specs from the app dir and collect ALL failures.

    Ordering contract for the caller: a failing block does NOT fail the phase.
    The runner did its job; the CODE is what failed. Hand this result to the
    builder and let the bounded repair loop decide the run's fate.
    """
    cwd = _app_dir(run)
    results = [_run(spec, run, cwd=cwd) for spec in checks]
    # A failure is the command, its exit code, and what it actually printed —
    # everything a builder needs to repair without opening a log or being told
    # what the error "means" by a parser that guessed.
    failures = [
        f"{check.name}: `{check.command}` exited {check.returncode}\n{check.output_tail}".rstrip()
        for check in results if not check.passed
    ]
    return QualityResult(
        passed=not failures,
        checks=results,
        failures=failures,
        artifacts=[check.output_artifact for check in results],
    )


def run_quality(run) -> QualityResult:
    """Run EVERY check the app declares, the test block included.

    This is the manifest-driven successor to the hardcoded block list: the app's
    `checks:` map is the whole specification. A manifest with no checks yields an
    empty, passing result (a logged note, not a failure) so the SDLC still runs
    plan/build/review.
    """
    checks = _load_checks(run)
    if not checks:
        run.console.note("quality: app manifest declares no checks — nothing to run")
    return _run_checks(run, checks)


def run_inkwell_quality(run) -> QualityResult:
    """Inkwell's six non-test blocks, for callers that predate the manifest.

    Behavior-identical to the old hardcoded list: for inkwell's manifest this is
    exactly frontend/backend lint, typecheck, and build.
    """
    return _run_checks(run, [c for c in _load_checks(run) if c.name != "tests"])


def run_inkwell_tests(run) -> QualityResult:
    """The manifest's `tests` block as a single-check QualityResult, so it reports
    like every other block. Kept for the callers that run tests as their own phase."""
    return _run_checks(run, [c for c in _load_checks(run) if c.name == "tests"])


def as_envelope(result: QualityResult, what: str) -> VerifyOutput:
    """Wrap a deterministic result so the builder can be handed it directly."""
    return VerifyOutput(
        status="success" if result.passed else "fail",
        summary=(f"{what}: all {len(result.checks)} check(s) passed" if result.passed
                 else f"{what}: {len(result.failures)} of {len(result.checks)} check(s) failed"),
        artifacts=result.artifacts,
        notes_for_next_agent=("" if result.passed else
                              "Fix every failure below. The output is verbatim from the "
                              "command — trust it over any summary."),
        passed=result.passed,
        failures=result.failures,
    )
