"""Prompt rendering: load system/user refs from config, replace {{placeholders}}.

The COMMIT-LANE v1 block is injected here, in the render funnel itself, so
no call site can omit it — every agent prompt carries the no-self-commit rule
by construction, not by orchestrator memory.
"""

from __future__ import annotations

from pathlib import Path

# The anchor the builder's prompt files must carry (see agents.validate) and
# the idempotency key render() checks before appending the block.
COMMIT_LANE_MARKER = "<!-- COMMIT-LANE v1 -->"

COMMIT_LANE_RULE = """
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
""".strip()


def render(template_path: str | Path, variables: dict[str, str]) -> str:
    text = Path(template_path).read_text()
    for key, value in variables.items():
        text = text.replace("{{" + key + "}}", value)
    # Inject as late as possible — after placeholder substitution, so no variable
    # can strip it. Idempotent: prompt files that already carry the block pass
    # through unchanged instead of doubling it.
    if COMMIT_LANE_MARKER not in text:
        text = text.rstrip() + "\n\n" + COMMIT_LANE_RULE + "\n"
    return text


def save(directory: str | Path, name: str, content: str) -> Path:
    """Save the exact prompt sent, before execution — the audit copy."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(content)
    return path
