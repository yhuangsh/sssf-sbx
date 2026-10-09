"""Low-level git operations for code phases. All low-level logic lives in adw_modules.

Every function takes an optional `repo`. `None` means the process cwd — the
factory clone — which is exactly the old behavior, so vendored runs are
unchanged. In phase-2 target mode the ADW products commit to the app's own
clone at `<factory>/<app.path>`, so the four ADW scripts resolve it once with
`payload_root()` and thread it through.

Agents are spawned in the resolved payload (`runner.Run.repo_root`), so in LOCAL
and TARGET modes their code, `specs/` and `app_docs/` products are written in the
payload clone and the chain's commit phases land them there. `payload_root()`
resolves that clone; `route_kernel_products()` is the safety net that moves any
stray factory-side `specs/<adw_id>_*.md` / `app_docs/<adw_id>_*.md` into the
payload before a commit, so the kernel tree is never committed to by an app run.
In VENDORED mode the payload IS the kernel, so routing is a no-op.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def _git(*args: str, repo: Path | str | None = None) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True, cwd=repo)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def payload_root(app_cfg, factory_root: Path) -> Path:
    """The repo ADW products commit to, resolved in three modes:

    - LOCAL: `app.local_path` is set and resolves to an existing git repo on
      the host → return that clone (the `just local` lane). `local_path` WINS
      over `repo`/`path`. The clone must live OUTSIDE the kernel tree — a
      `local_path` inside `factory_root` is a named error (the kernel is never
      the payload of an app run).
    - TARGET: no local clone, but `app.repo` is set AND `<factory_root>/<path>`
      is an existing git repo → return it (phase 2 target mode, in a VM).
    - VENDORED: neither → return `factory_root` itself.

    Fall-through rule: a `local_path` that is set but missing or not yet a git
    repo is NOT an error here — cloning is the mount's job, not the resolver's
    — so resolution falls through to TARGET/VENDORED. Host-side runs of a
    target-mode roster likewise have no clone at `<factory>/<path>` (FILL
    creates it only inside the VM); their products belong to the factory, so a
    missing or non-git target falls back to the factory root instead of
    crashing the first git call with FileNotFoundError."""
    factory = Path(factory_root).resolve()
    if app_cfg is not None and getattr(app_cfg, "local_path", None):
        local = Path(app_cfg.local_path).expanduser().resolve()
        if local.is_relative_to(factory):
            raise RuntimeError(
                f"payload_root: app.local_path '{local}' is inside the kernel tree "
                f"'{factory}' — the kernel is never the payload of an app run; "
                f"point local_path at a clone OUTSIDE the kernel")
        if local.is_dir() and is_repo(local):
            return local
    if app_cfg is not None and getattr(app_cfg, "repo", None):
        target = (Path(factory_root) / app_cfg.path).resolve()
        if target.is_dir() and is_repo(target):
            return target
    return factory


# Kernel-side products an app run relocates into the payload clone (local mode).
KERNEL_PRODUCT_DIRS = ("specs", "app_docs")


def route_kernel_products(adw_id: str, payload: Path, kernel_root: Path) -> list[Path]:
    """Local mode: MOVE this run's kernel-side products into `payload`.

    Globs `specs/<adw_id>_*.md` and `app_docs/<adw_id>_*.md` (only THIS run's id)
    in `kernel_root`, moving each to the same relative path under `payload`
    (parents created). Returns the moved files. No-op when `payload ==
    kernel_root` (vendored mode) or when nothing matches. Call immediately before
    a commit phase so the subsequent `commit_all(repo=payload)` lands the spec and
    write-up on the clone's run branch instead of leaving them in the kernel.
    """
    payload = Path(payload).resolve()
    kernel_root = Path(kernel_root).resolve()
    if payload == kernel_root:
        return []
    moved: list[Path] = []
    for folder in KERNEL_PRODUCT_DIRS:
        src_dir = kernel_root / folder
        if not src_dir.is_dir():
            continue
        for src in sorted(src_dir.glob(f"{adw_id}_*.md")):
            dst = payload / folder / src.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
            moved.append(dst)
    return moved


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
