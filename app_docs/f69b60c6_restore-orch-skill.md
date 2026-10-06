# Restore the sandbox-orchestrator surface

This change restores the two pieces the kernel import had dropped — the `just sbx orch` recipes and
the `.claude/skills/sssf-sandbox-orchestrator/` skill — **adapted to this kernel's actual
recipes**. No recipe behavior changed; the skill keeps its ancestor structure and its governing
principle (THIN SKILL, FAT RECIPES), and every command, check name, and semantic it teaches is
congruent with `just/sandbox/`, `sandbox_mount/`, and `README.md` as they exist here.

## Why it matters

The orchestrator skill is the document the boot recipes hand the host agent. Without it, the
`claude`/`pi` harnesses `just sbx orch cc / pi` invoke have no instructions to read. Without those
recipes, there is no host-side entry point for an orchestration-level agent at all — the
`sbx` namespace had `mount` + `lifecycle` + `manage` + `run` but no way to *boot* a worker that
drives those phases.

Both halves were rewritten, not blindly copy-pasted, because the kernel differs from the ancestor
in non-cosmetic ways:

- this kernel has **no `just local` module** — the in-sandbox factory level is `just adw` over
  `adws/`. The header's two-levels explanation in `orch/mod.just` was rewritten to match.
- `SSSF_CONFIG` is **required with no silent default**; the skill's guard, doctor's report, and
  the "set it before any roster-consuming command" rule all reflect this.
- there is **no `/sssf` or `/sandbox-exe-dev` skill** in `.claude/` — the skill's Dependencies
  section points at `README.md` and the recipes instead, and the ancestor's
  "factory skill present" / "VM skill present" `test -f` checks are gone, not rewired.
- doctor's real checks are five fixed labels (`ssh exe.dev reachable`,
  `run_record helper runs`, `provisioner present`, `roster provider keys set`,
  `adw layer resolves`) plus an arming-visibility line in vendored mode; the skill's doctor
  paragraph matches them line-for-line.

## Files that carry the change

| File | Role |
|---|---|
| `just/sandbox/mod.just` | adds `mod orch` and updates the SHAPE comment to list `just sbx orch` |
| `just/sandbox/orch/mod.just` | new module: `default` lists the harnesses; `cc` boots Claude Code, `pi` boots pi, both pointed at `.claude/skills/sssf-sandbox-orchestrator/SKILL.md` |
| `.claude/skills/sssf-sandbox-orchestrator/SKILL.md` | the skill body — lane mental model, SSSF_CONFIG rule, doctor output, the drive surface, the five gate assertions, the hard rules, cookbook/references index |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/just_command_model.md` | how `mod`/`import` actually work in `just`, why `just/adws.just` carries its own `set` lines, the `just adw sdlc` vs `just sbx lifecycle execute` warning |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/mount_one.md` | one-sandbox end-to-end: arming preflight → create → fill → setup → observe, with the run-record writer table |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/execute_work.md` | the three kickoff recipes (`run cmd`, `lifecycle execute`, `run agent`), the detach incantation, watching a detached run via `run.log` |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/observe_and_report.md` | `observe`'s six idempotent steps, the two URLs, the 307-is-correct rule, reading the trace db over `run cmd` |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/access_a_running_sandbox.md` | flow A (ssh for a shell) vs flow B (`ssh -t` + `pi --session-id` to resume the in-box agent) |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/debug_a_failed_gate.md` | per-assertion (A–E) recipes: what it proves, failure shapes, diagnose commands, read-it rules; the two false failures already paid for |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/fan_out_n.md` | best-of-N loop, why one-box-N-agents is not allowed, where variance belongs (prompt / `SSSF_CONFIG` / model), the unexercised golden-VM path |
| `.claude/skills/sssf-sandbox-orchestrator/cookbooks/teardown_and_reap.md` | artifacts → harvest → destroy → close; harvest-failure aborts the destroy; no `reap` in this kernel |
| `.claude/skills/sssf-sandbox-orchestrator/references/kickoff_paths.md` | direct (`lifecycle execute`) vs agent-mediated (`run agent`); the delegation contract that opens every work turn with "READ README.md and run just --list adw" |
| `specs/f69b60c6_restore-orch-skill.md` | the plan/scope artifact for this session |

## How to use or verify it

Boot the orchestrator with either harness from the kernel clone root:

```bash
just sbx orch cc    # Claude Code, pointed at the SKILL.md
just sbx orch pi    # pi, same posture
```

A bare `just sbx orch` lists the harnesses; `just sbx` lists the full namespace including `orch`.

Verify the recipe wiring:

```bash
just --list sbx::orch           # default / cc / pi
just --list sbx                 # mount + the four submodules + orch
just --show sbx::orch::cc       # body of the cc recipe
```

Verify the skill is congruent with the recipes (the congruence authority):

- **`SSSF_CONFIG` guard.** Unset `SSSF_CONFIG` and run `just sbx manage doctor` — the failure must
  quote `SSSF_CONFIG is not set — point it at your roster…` and exit 1 (guard:
  `sandbox_mount/host/require_sssf_config.sh`). The skill quotes this exact error in its
  `SSSF_CONFIG is required` section.
- **doctor output.** With `SSSF_CONFIG` set, `just sbx manage doctor` prints the five checks in
  this order, one per line: `ssh exe.dev reachable`, `run_record helper runs`, `provisioner present`,
  `roster provider keys set`, `adw layer resolves`. Each is `  ok <label>` or `  FAIL <label>`. In
  vendored mode (no `app.repo` in the roster) it appends an `app.path <path> present (armed)` line
  or an UNARMED warning that **never affects the exit code**. Ends `  sbx doctor: OK` (exit 0) or
  `  sbx doctor: FAILED` (exit 1). The skill's doctor paragraph mirrors this exactly.
- **gate details.** `just/sandbox/lifecycle/setup.just` runs the A/B/C/D/E gate and prints `PASS` /
  `FAIL` per assertion; the C/D/E shared script's exit codes 2/3/4 name which of C, D, E failed.
  Gate A filters `?? <app.path>/` from the clean-tree assertion, so custom paths need no
  `.gitignore` edit. `cookbooks/debug_a_failed_gate.md` documents this.
- **list the namespace correctly.** `just --list sbx` works; `just sbx --list` errors
  (`Justfile does not contain recipe `sbx --list``). The skill warns about this in its Dependencies
  section.
- **no stale tokens.** `grep -REn 'OPENROUTER_PROVISIONING_KEY|models\.json\.tmpl|/sandbox-exe-dev|apps/inkwell|just local' .claude/skills/sssf-sandbox-orchestrator/` returns nothing.

## What the change does NOT do

- No recipe under `just/sandbox/`, `just/adws.just`, or `sandbox_mount/` was modified. The five
  phase files (`mount.just` + `lifecycle/{create,fill,setup,execute,observe,teardown}.just`),
  the `manage/` recipes (`doctor`, `harvest`, `list`), and the `run/` recipes (`cmd`, `agent`)
  are untouched.
- The factory repo, the live app repos, and parked items are out of scope.
- The skill is the same SKILL/cookbooks/references skeleton as the ancestor; only the
  contents are adapted.