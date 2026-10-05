# Build Task

## Variables

### prompt

{{prompt}}

### previous_envelope

{{previous_envelope}}

### context_handoff_dir

{{context_handoff_dir}}

## Task

Implement the work described in `prompt`, guided by `previous_envelope` if present, then emit your `Report` JSON.

## Report

Respond with ONLY valid JSON matching `BuildOutput` — no prose before or after:

```json
{
  "status": "success",
  "summary": "<one sentence describing what you built>",
  "changed_files": ["src/server.ts"],
  "artifacts": [],
  "commit_message": "<imperative one-line git subject for the code you changed — this is what the commit of your work will say>",
  "notes_for_next_agent": "<how to verify this work>"
}
```

<!-- COMMIT-LANE v1 -->
## Commit lane — no self-commit

You are FORBIDDEN from every git ref mutation: commit, push (including
--delete), tag, branch create/delete/switch, checkout, switch, reset,
rebase, merge — INCLUDING `git checkout -- <path>` and any other
file-discarding form of checkout/restore.

Allowed git: `git add`, and read-only commands — status, diff, log, show,
rev-parse, branch --show-current / --list / -a, remote get-url.

The chain's kind="code" commit phases own every commit. Leave your work
dirty in the tree; do not try to "help" by committing it.

Your report's changed_files lists only files that exist afterwards;
deletions go in summary / notes_for_next_agent.
