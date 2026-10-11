# Fork decisions

2026-10-07: The fleet load baseline in `~/code/skills/docs/agent-load-baseline-2026-10-07.md` measured this repo's `AGENTS.md` at 29,144 characters plus about 11,000 characters of `.agents/skills` descriptions, the heaviest always-loaded item in the fleet.
Decision: no further fork-side shrink of `AGENTS.md` and no upstream proposal.
`AGENTS.md` and `bin/` are not identical to upstream: `AGENTS.md` still carries the earlier fork-side reduction from commit 3220f742 and is 226 lines shorter than upstream `main`, and 41 `bin/` files differ from upstream `main`, 38 of them through fork-only changes since the last upstream sync.
The fleet's own guidance load is measured by the skills store's `scripts/agent-load` instead.

2026-10-10: Arjun's 2026-10-07 dispatch phase 5 asked for narrow work to default to low effort and judgment to high, and for each task record to carry the typed dispatch verdict (rule, confidence, profile) so low-confidence picks are visible and tunable.
The private, gitignored `config/crew-dispatch.json` already encodes the effort split: rule 3 sends narrow bounded work to Opus 5.5 at low effort, rule 4 sends judgment work to Opus 5.5 at high effort, and the default is high.
Recording the verdict on each task record would need `bin/fm-dispatch-resolve.sh` or `bin/fm-spawn.sh` to write task metadata, which is a `bin/` change.
Decision: the effort split lives in the private config, and the verdict is not recorded automatically.
`bin/fm-dispatch-resolve.sh` prints the typed verdict at intake, and firstmate copies it into the task body by hand when it matters.
No `bin/` change and no upstream proposal.
Reopen this if upstream adds a dispatch-verdict field to task records.
