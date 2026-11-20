2026-11-20: Arjun approved deep-audit item a1-20 at his helm walk of the 2026-11-19 audit: the home layout had two owners, `docs/configuration.md` "Operational home layout and state" and the `operational-home-layout` skill, whose broad trigger loaded it for any home path.
Decision: the doc section stays the one owner; the skill opens by naming it and saying it is only the per-file index beneath it, and its trigger narrows to a single file under `config/`, `data/`, or `state/` that the section does not name.
Its `pipeline-spend` entries stay, because `bin/fm-pipeline-spend.sh` and `docs/configuration.md` still carry that opt-in.
No upstream proposal yet: upstream has the same two owners.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The layout skill defers to the doc section and narrows its trigger | `.agents/skills/operational-home-layout/SKILL.md` (description, opening) | same file | carried | 427056c4 |
