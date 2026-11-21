2026-11-21: Arjun picked "One full suite per task" for the fleet repository after the CI batching scout: light checks while a fleet PR is a draft, and the full suite once when it is marked ready.
Decision: a direct-PR worker whose repository's own guidance has its PRs opened as drafts until their reviews are done opens the PR as a draft, runs the code review on the draft, and marks it ready after its last review push, before it waits for checks.
After marking it ready, the worker confirms a run the ready event started exists at its head, because the job a draft skipped counts as a passing check until that run registers.
The repository's guidance owns the rule, so the Definition of done names no repository, and every other repository keeps opening its PR ready for review.
The done report still needs a non-draft PR, and the merge guards are unchanged.
No upstream proposal yet: the rule follows this fleet's own CI shape.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The direct-PR Definition of done defers to a repository that opens PRs as drafts until reviewed, and waits for the ready run before trusting checks | `bin/fm-dod-lib.sh` (`fm_dod_block` direct-PR text, `fm_dod_checks_green_block`), `tests/fm-dod-lib.test.sh` | same files | carried | 427056c4 |
