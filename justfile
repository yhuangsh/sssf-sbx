set dotenv-load
set positional-arguments

# Recipes run through an INTERACTIVE zsh so the engineer's own profile is live
# (harnesses installed as shell functions resolve). `.env` still wins over the
# profile (dotenv-load applies to the recipe environment). A recipe with its own
# `#!` shebang bypasses this setting entirely.
set shell := ["zsh", "-ic"]

export SHELL_SESSIONS_DISABLE := "1"

# SSSF_CONFIG is REQUIRED — there is no default roster. Each consuming module
# enforces it (see sandbox_mount/host/require_sssf_config.sh); the module's own
# `config` variable would be invisible here anyway, so there is none at the root.

# Two layers, deliberately separate:
#   `mod adw` — IN-sandbox execution: the ADWs themselves; identical whether run
#               here or on a VM that has this repo.
#   `mod sbx` — OUT-of-sandbox orchestration: creates, fills, and observes the
#               VMs the ADWs run inside. It ships to the sandbox like everything
#               else; what a sandbox cannot do is USE it, because the exe.dev
#               account never leaves the host.

# the ADWs themselves: just adw sdlc "..."
mod adw 'just/adws.just'

# sandbox orchestration: mount, execute, observe, tear down VMs
mod sbx 'just/sandbox/mod.just'

# local development: the full sssf workflow on the host, payload in a local clone.
# NOT the factory repo's local.just — this kernel's `local` is the local dev lane.
mod local 'just/local.just'

# read the trace db: sessions, phases, tail, procs
mod obs 'just/obs.just'

# list commands
default:
    @just --list
