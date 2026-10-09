"""State-root resolution for the chain internals (session runtime + trace db).

The kernel accumulates NOTHING from an app run. Where a run's live trace db and
session directory live follows one rule, resolved from the parsed roster:

- LOCAL mode (`app.local_path` names an existing clone on this host) ->
  `<local_path>/sssf/`  (db at `<local_path>/sssf/sssf.db`, sessions beside it).
- VENDORED/kernel-self (no `app.repo`, no usable local clone) -> `None`, i.e.
  the roster's configured `defaults.data_dir` / `observability.db` — the kernel's
  own `adws/adw_data/`. Those artifacts belong to the kernel project.

Why `local_path` must EXIST locally, not merely be set: FILL ships the roster
(vitally, `app.local_path` and all) verbatim into a sandbox, and inside the VM
the host's `local_path` is not a path on that filesystem. There the in-VM chain
must keep kernel locations so teardown's VM-relative tar set (`$DB_REL`) still
finds the db; the host-side artifacts then re-home via run_record's rule. Host
LOCAL mode runs the chain on the host, where the clone really exists, so it
re-homes. Rule (b) of the state-root spec (`~/.sssf/apps/<app-key>/` for
sandbox-only target mode) is host-side state and is implemented in
`run_record.resolve_state_root`; this module deliberately does not apply it
inside a VM for the reason above.
"""

from __future__ import annotations

import re
from pathlib import Path

HOME_APPS = Path.home() / ".sssf" / "apps"


def app_key(repo_url: str) -> str:
    """Sanitized basename of an app repo URL (see run_record.app_key)."""
    base = (repo_url or "").rstrip("/").rsplit("/", 1)[-1]
    if base.endswith(".git"):
        base = base[:-4]
    key = re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")
    return key or "app"


def resolve(app) -> Path | None:
    """The state root for an app config, or None = kernel/vendored locations.

    Property access is defensive (`getattr`) so this is safe on a None app and on
    a partially-populated config in tests.
    """
    if app is None:
        return None
    local = getattr(app, "local_path", None)
    if local:
        clone = Path(local).expanduser()
        if clone.is_dir():
            return clone / "sssf"
        return None                      # named but not present here (e.g. in a VM)
    return None


def effective_data_dir(app, configured: str) -> Path:
    """`<state_root>` when it resolves, else the configured data_dir."""
    root = resolve(app)
    return root if root is not None else Path(configured)


def effective_db(app, configured: str) -> Path:
    """`<state_root>/sssf.db` when it resolves, else the configured db path."""
    root = resolve(app)
    return (root / "sssf.db") if root is not None else Path(configured)
