2026-11-20: Arjun approved deep-audit item a1-18 at his helm walk of the 2026-11-19 audit: the trigger index skill had drifted from the skill descriptions, omitting `firstmate-self-repo` and shortening four others.
Decision: `agent-skill-trigger-index` keeps no copy of the triggers and points at each skill's own `description`, which the harness already loads as the one complete index (`AGENTS.md` section 13).
A parity test was the other option; it would assert source bytes, which the coding guidelines forbid, and a pointer has nothing to drift.
No upstream proposal yet: upstream's index carries the same copy and could take the same pointer.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The trigger index skill points at the skill descriptions instead of copying them | `.agents/skills/agent-skill-trigger-index/SKILL.md` | same file | carried | 427056c4 |
