2026-11-20: Arjun approved deep-audit item a1-13 at his helm walk of the 2026-11-19 audit, extending the [2026-11-19 AGENTS.md delivery trim](2026-11-19-agents-md-delivery-trim.md) to the rest of the retired no-mistakes text that still steered work.
Decision: new projects default to `direct-PR` and skip no-mistakes initialization, ship intake no longer classifies a `no-mistakes-prod-only` surface, and the selected-path text no longer offers no-mistakes as an escalation.
The `validation-supervision` ask-user trigger in `AGENTS.md` section 7 and the `stuck-crewmate-recovery` no-mistakes clause stay, as the merged guidance-16 half of the finding recommended: Arjun reviewed that text on 2026-11-19 and kept it.
The scripts keep their no-mistakes support, as the 2026-11-19 record says, so `bin/fm-home-seed.sh`, `bin/fm-remote-home-provision.sh`, `bin/fm-brief.sh`, and `secondmate-provisioning` still run its initialization for a legacy entry.
No upstream proposal: upstream still ships the pipeline as its default delivery path.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| New projects default to direct-PR with no no-mistakes initialization step | `.agents/skills/project-management/SKILL.md` (Delivery posture, Add or clone, Create, Initialize removed) | same file | carried | 427056c4 |
| Ship intake and the selected-path text drop the no-mistakes branches | `docs/task-lifecycle.md` (Intake, Selected delivery path) | none (fork-only doc) | carried | 427056c4 |
| The self-update skill names the PR gate | `.agents/skills/updatefirstmate/SKILL.md` | same file | carried | 427056c4 |
