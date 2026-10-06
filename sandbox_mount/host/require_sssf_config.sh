#!/usr/bin/env bash
# require_sssf_config.sh — print the active roster path or fail with THE named error.
#
# There is no default roster any more: adws/adw_sssf_config/sssf.config.yaml is
# a template, never implicitly selected. Every roster-consuming host command
# routes through here — directly from the shell recipes (mount, fill, teardown,
# harvest, doctor, create) or via a just `_require-sssf-config` dependency (the
# `obs` queries). The python chains carry their own copy of the same message in
# adw_modules/utils.py (require_config); the two must stay byte-identical.
#
# The deliberate NON-consumers keep their shipped-copy mechanism and never call
# this: setup/execute/observe read /home/exedev/sssf_config.yaml, which FILL put
# there verbatim — that is the ssh-carries-no-environment path, not a default.
#
# Usage: ROSTER=$(sandbox_mount/host/require_sssf_config.sh)
set -uo pipefail
if [ -z "${SSSF_CONFIG:-}" ]; then
    echo "SSSF_CONFIG is not set — point it at your roster (add 'SSSF_CONFIG=adws/adw_sssf_config/sssf.<your-app>.config.yaml' to .env, or export it inline). See README -> Arming." >&2
    exit 1
fi
printf '%s\n' "$SSSF_CONFIG"
