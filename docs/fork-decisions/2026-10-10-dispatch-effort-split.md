2026-10-10: Arjun's 2026-10-07 dispatch phase 5 asked for narrow work to default to low effort and judgment to high, and for each task record to carry the typed dispatch verdict (rule, confidence, profile) so low-confidence picks are visible and tunable.
The private, gitignored `config/crew-dispatch.json` already encodes the effort split: rule 3 sends narrow bounded work to Opus 5.5 at low effort, rule 4 sends judgment work to Opus 5.5 at high effort, and the default is high.
Recording the verdict on each task record would need `bin/fm-dispatch-resolve.sh` or `bin/fm-spawn.sh` to write task metadata, which is a `bin/` change.
Decision: the effort split lives in the private config, and the verdict is not recorded automatically.
`bin/fm-dispatch-resolve.sh` prints the typed verdict at intake, and firstmate copies it into the task body by hand when it matters.
No `bin/` change and no upstream proposal.
Reopen this if upstream adds a dispatch-verdict field to task records.
