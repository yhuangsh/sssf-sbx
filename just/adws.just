# In-sandbox execution layer: every ADW, mounted at the root as `mod adw`.
# Nothing here talks to a VM — these are the same commands whether you run them
# on your machine or inside a sandbox that has the repo at /home/exedev/app.

# A `mod` runs with cwd set to the MODULE'S directory (just/), so `adws/` would
# be invisible and every recipe would die with "No such file or directory".
set working-directory := '..'

# A `mod` also does NOT inherit parent variables or settings — `config`,
# positional args, and dotenv all have to be declared again here.
#
# SSSF_CONFIG is REQUIRED — there is no default roster. When it is unset we add
# NO --config at all (rather than an empty one), so the chain's own
# utils.require_config() fails fast with THE named error. When it is set we pass
# it first; a trailing explicit --config (the sandbox `execute` lane) still wins
# because argparse keeps the LAST one. The engine's default is deliberately NOT
# the placeholder template — see sandbox_mount/host/require_sssf_config.sh.
config := env_var_or_default("SSSF_CONFIG", "")
cfg := if config == "" { "" } else { " --config " + config }
set positional-arguments
set dotenv-load

# No `set shell` on purpose. The root justfile uses interactive zsh so the
# engineer's shell functions resolve; zsh is not installed in the sandbox image,
# and these recipes only ever call the `uv` binary. In the sandbox, invoke as:
#   just --shell bash --shell-arg -c adw <recipe> ...
# (the default `sh` there is dash, which does not understand `${@:2}` in `ask`)

# list adw recipes — without this, a bare `just adw` runs the first recipe below
default:
    @just --justfile {{source_file()}} --list

# ── raw ADW runs (args pass straight through: "prompt" [--adw-id X] [--config Y]) ──

# one agent, one prompt (add --agent NAME to pick; default builder)
prompt *ARGS:
    uv run adws/adw_prompt.py{{cfg}} "$@"

# pick the agent by name: just ask scout "where does auth live"
ask AGENT *ARGS:
    uv run adws/adw_prompt.py{{cfg}} --agent {{AGENT}} "${@:2}"

# read-only recon
scout *ARGS:
    uv run adws/adw_scout.py{{cfg}} "$@"

# plan only
plan *ARGS:
    uv run adws/adw_plan.py{{cfg}} "$@"

# one-shot implementation, no plan
build *ARGS:
    uv run adws/adw_build.py{{cfg}} "$@"

# planner → builder
plan-build *ARGS:
    uv run adws/adw_plan_build.py{{cfg}} "$@"

# builder → deterministic test with bounded fix loop
build-test *ARGS:
    uv run adws/adw_build_test.py{{cfg}} "$@"

# builder → reviewer with bounded revise loop (is it what was asked for?)
build-review *ARGS:
    uv run adws/adw_build_review.py{{cfg}} "$@"

# deterministic only: lint, typecheck, build (pass the reason for the run)
quality *ARGS:
    uv run adws/adw_quality.py{{cfg}} "$@"

# write up the work just done, from git diff vs main (add --base REF to change it)
document *ARGS:
    uv run adws/adw_document.py{{cfg}} "$@"

# the full chain: plan → build → deterministic test/fix
sdlc *ARGS:
    uv run adws/adw_plan_build_test.py{{cfg}} "$@"

# sdlc plus a deterministic quality block at the end
plan-build-test-quality *ARGS:
    uv run adws/adw_plan_build_test_quality.py{{cfg}} "$@"

# plan → build → test → review → document, committing the plan, the code, and the docs separately
simple-sdlc *ARGS:
    uv run adws/adw_simple_sdlc.py{{cfg}} "$@"
