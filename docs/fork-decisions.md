# Fork decisions

2026-10-07: The fleet load baseline in `~/code/skills/docs/agent-load-baseline-2026-10-07.md` measured this repo's `AGENTS.md` at 29,144 characters plus about 11,000 characters of `.agents/skills` descriptions, the heaviest always-loaded item in the fleet.
Decision: `AGENTS.md` and `bin/` stay exactly as upstream ships them, with no fork-side shrink and no upstream proposal.
The fleet's own guidance load is measured by the skills store's `scripts/agent-load` instead.
