# just/sandbox/scaffold.just — interactive app-repo scaffolder.
#
# Lives next to mount.just so the whole `sbx` surface sits in one directory.
# Imported by mod.just, so no `set` lines here — it inherits the module's
# working-directory (the repo root) and dotenv-load.
#
# `gh` is a HARD dependency of THIS command only: the Python script checks
# `command -v gh` + `gh auth status` up front and fails with named guidance.
# exec, so signals and stdin behave exactly like the bare script — the flow is
# interactive, and a piped here-doc must reach input() untouched.

# interactively scaffold a GitHub app repo + roster this kernel can mount out of the box
scaffold REPO='':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{REPO}}" ]; then
        exec uv run sandbox_mount/host/scaffold.py "{{REPO}}"
    else
        exec uv run sandbox_mount/host/scaffold.py
    fi
