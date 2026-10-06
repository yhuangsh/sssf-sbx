#!/usr/bin/env -S uv run
# /// script
# dependencies = ["pydantic", "python-dotenv", "pyyaml", "rich"]
# ///
"""ADW Build — one-shot implementation workflow.

Usage:
    uv run adws/adw_build.py "<prompt or path/to/prompt.md>" [--config <roster>] [--adw-id a1b2c3d4]
    --config / SSSF_CONFIG is REQUIRED — there is no default roster; with neither, the chain fails fast with the named error (README -> Which commands need SSSF_CONFIG).

Phases: engineer(request) -> builder
"""

import argparse
import sys

from adw_modules import agents, gates, session, utils
from adw_modules.data_types import AgentCall, BuildOutput, PhaseParams

REQUIRED_AGENTS = ["builder"]


def main(prompt: str, config: str, adw_id: str | None = None) -> int:
    cfg = agents.load_config(config)
    agents.validate(cfg, REQUIRED_AGENTS)
    run = session.ensure(cfg, adw_id)

    with run.phase(PhaseParams(name="request", kind="engineer", owner=run.engineer,
                               description="Capture the incoming ask")) as ph:
        ph.log(input=prompt)

    with run.phase(PhaseParams(name="build", kind="agent", owner="builder", retries=1,
                               description="Implement the request")) as ph:
        ph.call(AgentCall(output_type=BuildOutput, prompt=prompt,
                          gates=[gates.diff_matches_claims]))

    return run.finish()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", help="inline text or a path to a prompt file")
    parser.add_argument("--config", default=None, help="roster path — required (SSSF_CONFIG or explicit)")
    parser.add_argument("--adw-id", default=None, help="join or pin an existing session")
    args = parser.parse_args()
    args.config = utils.require_config(args.config)
    sys.exit(main(utils.resolve_prompt(args.prompt), args.config, args.adw_id))
