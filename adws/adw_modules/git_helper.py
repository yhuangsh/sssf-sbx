"""Low-level git operations for code phases. All low-level logic lives in adw_modules.

Every function takes an optional `repo`. `None` means the process cwd — the
factory clone — which is exactly the old behavior, so vendored runs are
unchanged. In phase-2 target mode the ADW products commit to the app's own
clone at `<factory>/<app.path>`, so the four ADW scripts resolve it once with
`payload_root()` and thread it through. The factory clone is then never
committed to inside a sandbox; `specs/` and `app_docs/` products live
factory-side, uncommitted, and ride home in the teardown tar.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def _git(*args: str, repo: Path | str | None = None) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True, cwd=repo)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def payload_root(app_cfg, factory_root: Path) -> Path:
    """The repo ADW products commit to: the target clone when the roster's app
    block names a repo AND the clone is checked out (phase 2 target mode, in
    a VM), else the factory repo itself (vendored payload — byte-identical to
    the old behavior).

    Host-side runs of a target-mode roster have no clone at <factory>/<path>
    (FILL creates it only inside the VM); their products belong to the factory,
    so a missing or non-git target falls back to the factory root instead of
    crashing the first git call with FileNotFoundError."""
    if app_cfg is not None and getattr(app_cfg, "repo", None):
        target = (Path(factory_root) / app_cfg.path).resolve()
        if target.is_dir() and is_repo(target):
            return target
    return Path(factory_root).resolve()


def current_branch(repo: Path | str | None = None) -> str:
    return _git("rev-parse", "--abbrev-ref", "HEAD", repo=repo)


def create_branch(name: str, repo: Path | str | None = None) -> str:
    _git("checkout", "-b", name, repo=repo)
    return name


def is_repo(repo: Path | str | None = None) -> bool:
    result = subprocess.run(["git", "rev-parse", "--git-dir"],
                            capture_output=True, text=True, cwd=repo)
    return result.returncode == 0


def repo_root() -> Path:
    """Absolute root of the codebase — where agents are spawned to work.

    The git toplevel when there is one, else the process cwd (ADWs run fine in a
    non-git dir; only a commit phase requires a repo). Always absolute, so it is
    safe to hand to a subprocess regardless of where the ADW was launched from.
    """
    if is_repo():
        return Path(_git("rev-parse", "--show-toplevel")).resolve()
    return Path.cwd().resolve()


def commit_all(message: str, repo: Path | str | None = None,
               allow_empty: bool = False) -> str:
    """Stage the working tree and commit it. Returns the new short sha.

    With `allow_empty` a clean tree returns "" instead of raising — used by the
    phases whose product is intentionally factory-side in target mode (the plan
    in `specs/`, the write-up in `app_docs/`). The strict raise stays the default.
    """
    if not is_repo(repo):
        raise RuntimeError(
            "not a git repository — a commit phase needs one. Run `git init` in the "
            "repo root (and make a first commit) before running an ADW that commits.")
    _git("add", "-A", repo=repo)
    if not _git("status", "--porcelain", repo=repo):
        if allow_empty:
            return ""
        raise RuntimeError("nothing to commit — the preceding phases changed no files")
    _git("commit", "-m", message, repo=repo)
    return _git("rev-parse", "--short", "HEAD", repo=repo)


def changed_files(repo: Path | str | None = None) -> list[str]:
    out = _git("status", "--porcelain", repo=repo)
    return [line[3:] for line in out.splitlines() if line]


# ── diff plumbing (composed into a ChangeSet by documentation.py) ────────────

def ref_exists(ref: str, repo: Path | str | None = None) -> bool:
    """True when `ref` resolves to a commit. Never raises — this is a question."""
    result = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                            capture_output=True, text=True, cwd=repo)
    return result.returncode == 0


def rev(ref: str = "HEAD", repo: Path | str | None = None) -> str:
    return _git("rev-parse", ref, repo=repo)


def short_sha(ref: str = "HEAD", repo: Path | str | None = None) -> str:
    return _git("rev-parse", "--short", ref, repo=repo)


def merge_base(ref: str, other: str = "HEAD", repo: Path | str | None = None) -> str:
    """The commit where `ref` and `other` diverged — the honest base of a branch.

    On the base branch itself this returns HEAD, which makes the diff exactly
    "what is not committed yet". Off it, the diff is the whole branch plus the
    working tree. One command covers both cases, so no ADW has to branch on it.
    """
    return _git("merge-base", ref, other, repo=repo)


def is_dirty(repo: Path | str | None = None) -> bool:
    return bool(_git("status", "--porcelain", repo=repo))


def untracked_files(repo: Path | str | None = None) -> list[str]:
    out = _git("ls-files", "--others", "--exclude-standard", repo=repo)
    return [line for line in out.splitlines() if line]


def diff_files(base: str, repo: Path | str | None = None) -> list[str]:
    """Tracked files that differ between `base` and the working tree."""
    out = _git("diff", "--name-only", base, repo=repo)
    return [line for line in out.splitlines() if line]


def diff_stat(base: str, repo: Path | str | None = None) -> str:
    return _git("diff", "--stat", base, repo=repo)


def diff_counts(base: str, repo: Path | str | None = None) -> tuple[int, int]:
    """(insertions, deletions) across the diff. Binary files count as neither."""
    insertions = deletions = 0
    for line in _git("diff", "--numstat", base, repo=repo).splitlines():
        added, removed, *_ = line.split("\t")
        if added.isdigit():
            insertions += int(added)
        if removed.isdigit():
            deletions += int(removed)
    return insertions, deletions


def diff_text(base: str, repo: Path | str | None = None) -> str:
    return _git("diff", base, repo=repo)
