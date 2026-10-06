# just/sandbox/orch/mod.just — boot an agent at the ORCHESTRATION level.
#
# There are two levels, and booting the wrong one is the classic mistake:
#
#   just adw <recipe>      FACTORY level. The recipes in just/adws.just over
#                          adws/ — plan, build, test, review, document. They are
#                          identical on the host and inside a sandbox, which is
#                          exactly why they must only be DRIVEN through a sandbox
#                          phase: `just sbx lifecycle execute`, or
#                          `just sbx run cmd ... 'just --shell bash --shell-arg -c
#                          adw <recipe> ...'`. Running `just adw sdlc "..."`
#                          directly here runs the factory on your laptop, which is
#                          the one thing this whole system exists to prevent.
#
#   just sbx orch cc / pi  ORCHESTRATION level. Reads
#                          .claude/skills/sssf-sandbox-orchestrator/SKILL.md and
#                          drives the phases: mount, execute, observe, harvest,
#                          tear down. Belongs on the HOST: it needs the exe.dev
#                          account, which never reaches a sandbox.
#
# The per-app input is the roster's `app:` block (`repo`/`ref`/`path`/`manifest`).
# With `repo` set, FILL clones that repo to `~/app/<path>` in the VM, the run
# branch `sbx/<id>` and every ADW commit live on that clone, and HARVEST bundles
# from it — the factory clone stays byte-identical across apps. No `repo` keeps
# the payload vendored in the factory clone. The VM tag derives from `app.repo`
# (or an explicit mount arg) and is recorded in the run record.
#
# A module inherits nothing, so the settings are repeated here with one more `..`
# than the parent.
set working-directory := '../../..'
set positional-arguments
set dotenv-load

# list the orchestrator harnesses
default:
    @just --list sbx::orch

# boot the sandbox orchestrator (Claude Code)
cc:
    claude --dangerously-skip-permissions "Read and Execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md"

# same posture, pi harness
pi:
    pi "Read and Execute .claude/skills/sssf-sandbox-orchestrator/SKILL.md"

# To steer the agent already running INSIDE a mounted sandbox, use the run layer
# instead:  just sbx run agent RUN_ID "<prompt>"  (see just/sandbox/run/mod.just).
# It is host-side like everything here, but it drives pi on the VM over a
# resumable --session-id. There was briefly a `steer` alias for it; two names
# for one behavior, split across two files, is worse than one.
#
# There was also an `orchestrate-with "<task>"` that booted the orchestrator with
# a task already in hand. Dropped: `just sbx orch cc` and then typing the task is
# the same thing with one fewer recipe to keep in sync.
