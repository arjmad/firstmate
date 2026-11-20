2026-11-20: Arjun approved deep-audit item a7-25, relayed by the main firstmate: a secondmate hands every idea and captain call to the main home and never holds one locally, because the main home's Monday idea sweep reads only the main home.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The secondmate parent-channel note states the hand-off rule and amends its escalated-decision row, the captain-hold lifecycle keeps a mate's local row only as its gate's record, and the noticed queue points a secondmate at the rule instead of saying it files into its own backlog | `docs/secondmate-parent-channel.md`, `docs/captain-hold-lifecycle.md`, `.agents/skills/captain-hold-lifecycle/SKILL.md`, `.agents/skills/noticed-queue/SKILL.md` | `docs/secondmate-parent-channel.md`, `docs/captain-hold-lifecycle.md`, `.agents/skills/captain-hold-lifecycle/SKILL.md` | carried | 427056c4 |
| A research scout's brief names the `research` skill's filing step; the skill was renamed from `research-playbook` | `bin/fm-brief.sh` (rule 2) | the rule 2 memory-route line in `bin/fm-brief.sh` | carried | 427056c4 |
