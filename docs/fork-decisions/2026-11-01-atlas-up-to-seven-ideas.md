2026-11-01: Arjun answered the Atlas reconcile board's idea-count card "zero-to-seven" on 2026-11-01.
Decision: an Atlas build carries only the ideas that pass the idea bar, from none to seven, so it no longer fills seven slots; this changes the count in the 2026-10-26 record `2026-10-26-atlas-ideas-reach-bearings.md`.
Why: the first build's seven ideas were all dropped within a minute while only one captured idea was waiting, so a fixed seven forced invented ideas, and an empty build still refreshes the map and records its board link.
No upstream proposal: Atlas is this fork's own patch (2026-10-26).

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `fm-atlas.sh file` accepts a build of zero to seven ranked ideas and still refuses eight or more, and the idea bar's Atlas trigger and wording say Atlas's ideas rather than its top 7 | `bin/fm-atlas.sh` (`valid_atlas`, header), `tests/fm-atlas.test.sh`, `docs/scripts.md`, `.agents/skills/noticed-queue/SKILL.md` (description, The idea bar), `.agents/skills/agent-skill-trigger-index/SKILL.md` | none (fork-only script and skill) | carried | 45dd50a5 |
