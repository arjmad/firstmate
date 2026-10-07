# Fork decisions

2026-10-07: The fleet load baseline in `~/code/skills/docs/agent-load-baseline-2026-10-07.md` measured this repo's `AGENTS.md` at 29,144 characters plus about 11,000 characters of `.agents/skills` descriptions, the heaviest always-loaded item in the fleet.
Decision: no further fork-side shrink of `AGENTS.md` and no upstream proposal.
`AGENTS.md` and `bin/` are not identical to upstream: `AGENTS.md` still carries the earlier fork-side reduction from commit 3220f742 and is 226 lines shorter than upstream `main`, and 41 `bin/` files differ from upstream `main`, 38 of them through fork-only changes since the last upstream sync.
The fleet's own guidance load is measured by the skills store's `scripts/agent-load` instead.
