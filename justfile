set dotenv-load
set positional-arguments

# Recipes run through an INTERACTIVE zsh so the engineer's own profile is live
# (harnesses installed as shell functions resolve). `.env` still wins over the
# profile (dotenv-load applies to the recipe environment). A recipe with its own
# `#!` shebang bypasses this setting entirely.
set shell := ["zsh", "-ic"]

export SHELL_SESSIONS_DISABLE := "1"

# default config every run uses — override: SSSF_CONFIG=other.yaml just adw sdlc "..."  (or pass --config in args)
config := env_var_or_default("SSSF_CONFIG", "adws/adw_sssf_config/sssf.config.yaml")

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

# read the trace db: sessions, phases, tail, procs
mod obs 'just/obs.just'

# list commands
default:
    @just --list
