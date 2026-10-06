#!/usr/bin/env -S uv run
# /// script
# dependencies = ["pydantic", "python-dotenv", "pyyaml", "rich"]
# ///
"""ADW Plan — one-shot planning workflow.

Usage:
    uv run adws/adw_plan.py "<prompt or path/to/prompt.md>" [--config <roster>] [--adw-id a1b2c3d4]
    --config / SSSF_CONFIG is REQUIRED — there is no default roster; with neither, the chain fails fast with the named error (README -> Which commands need SSSF_CONFIG).

Phases: engineer(request) -> planner
"""

import argparse
import sys

from adw_modules import agents, gates, session, utils
from adw_modules.data_types import AgentCall, PhaseParams, PlanOutput

REQUIRED_AGENTS = ["planner"]


def main(prompt: str, config: str, adw_id: str | None = None) -> int:
    cfg = agents.load_config(config)
    agents.validate(cfg, REQUIRED_AGENTS)
    run = session.ensure(cfg, adw_id)

    with run.phase(PhaseParams(name="request", kind="engineer", owner=run.engineer,
                               description="Capture the incoming ask")) as ph:
        ph.log(input=prompt)

    with run.phase(PhaseParams(name="plan", kind="agent", owner="planner",
                               description="Turn the request into an implementable plan")) as ph:
        ph.call(AgentCall(output_type=PlanOutput, prompt=prompt,
                          gates=[gates.artifacts_exist, gates.files_non_empty]))

    return run.finish()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", help="inline text or a path to a prompt file")
    parser.add_argument("--config", default=None, help="roster path — required (SSSF_CONFIG or explicit)")
    parser.add_argument("--adw-id", default=None, help="join or pin an existing session")
    args = parser.parse_args()
    args.config = utils.require_config(args.config)
    sys.exit(main(utils.resolve_prompt(args.prompt), args.config, args.adw_id))
