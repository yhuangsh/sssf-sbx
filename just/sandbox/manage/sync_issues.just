# just/sandbox/manage/sync_issues.just — reconcile issues left open by a dead watcher.
#
# Imported by manage/mod.just (a module owns the `set` lines), so no settings
# here. Every execute spawns a host-side watcher that closes the run's issue when
# the session ends; that watcher dies if the host reboots, if it is killed, or if
# the tracker hit a transient gh error. This sweep is the backstop: for every run
# record whose issue is still open it reads the trace (live VM, else the
# teardown-pulled artifact copy) and closes the issue with the real outcome.
#
# Best-effort and idempotent: an already-closed issue just has its run-record
# state reconciled; a genuinely running session is left alone.

# sweep run records for finished sessions whose issues are still open
sync-issues:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{ justfile_directory() }}"
    if [ "${SSSF_ISSUES:-1}" = "0" ]; then
        echo "sync-issues: disabled (SSSF_ISSUES=0)"
        exit 0
    fi
    uv run sandbox_mount/host/issue_tracker.py sync
