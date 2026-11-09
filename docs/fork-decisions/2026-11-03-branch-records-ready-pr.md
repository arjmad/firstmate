2026-11-03: Arjun decided in the helm grill that the supervision branch records a ready PR itself when its task has no `pr=` yet, then merges it under its standing merge class.
Evidence: branch outcome seq 6940 on kempf-channel-entries reported "could not merge (task has no recorded PR)" for PR 667, leaving a merge the standing class already allowed to the helm.
The branch runs `bin/fm-pr-check.sh <task> <url>` with the URL copied from the worker's `done:` or checks-green ready line, exactly as ship-landing tells the helm, so recording stays in that one script and every merge guard stays as it was.
No upstream proposal: the branch's standing merge class is this fork's own patch ([branch standing merges](2026-10-27-branch-standing-merges.md)).

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The branch prompt's standing merges tell the branch to record a ready PR whose task lacks `pr=` through `bin/fm-pr-check.sh` before merging it, and say a missing `pr=` alone never leaves the merge to main | `bin/fm-branch-prompt.sh` ("Standing merges"), `tests/fm-branch-supervision.test.sh` (prompt rule), `tests/fm-pr-merge.test.sh` (`test_attended_branch_records_a_ready_pr_then_merges_it`) | none (fork-owned standing merge prose) | carried | c8d8fdad |
