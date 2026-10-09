# COMPARE. Side-by-side report for two or more runs — read-only.
#
# Imported into the root justfile, so no `set` lines here and no local variables:
# the phase files share one scope and a duplicate name across them is a hard error.
#
# The ranking view for competing fan-out arms: `just sbx manage harvest <id>
# --no-merge` each arm, then `just sbx manage compare <id1> <id2> ...` for the
# outcome, commits, diffstat, tokens+cost and issue link. Never touches a VM, a
# ref, or a check.

# compare two or more runs side by side: just sbx manage compare <id1> <id2> [...]
compare *RUN_IDS:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"

    # Through a variable, not straight into `for ... in`: an empty variadic
    # interpolated into the list is a syntax error.
    IDS="{{ RUN_IDS }}"
    set -- $IDS
    if [ "$#" -lt 2 ]; then
        echo "compare: need at least two run ids (got $#)"
        exit 2
    fi
    uv run sandbox_mount/host/compare_runs.py "$@"
