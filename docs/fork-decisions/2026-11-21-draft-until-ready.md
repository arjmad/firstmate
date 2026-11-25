2026-11-21: Arjun picked "One full suite per task" for the fleet repository after the CI batching scout: light checks while a fleet PR is a draft, and the full suite once when it is marked ready.
Decision: a direct-PR worker whose repository's own guidance has its PRs opened as drafts until their reviews are done opens the PR as a draft, does its reviews on the draft, and marks it ready after its last review push, before it waits for checks.
The repository keeps a draft head from carrying a passing required check, so the wait for a required check that has not reported, which now says to watch again until it posts and passes, covers the time before the ready run posts.
Correction 2026-11-25: this fork has no required checks; a draft fails its `Ready for review` check and skips the full suite, and the worker marks the PR ready before its checks wait, so the wait sees the ready run (`2026-11-24-ci-draft-gate.md`).
The repository's guidance owns the rule, so the Definition of done names no repository, and every other repository keeps opening its PR ready for review.
The done report still needs a non-draft PR, and the merge guards are unchanged.
No upstream proposal yet: the rule follows this fleet's own CI shape.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The direct-PR Definition of done defers to a repository that opens PRs as drafts until reviewed, and makes a draft's local full suite optional where CI runs it at ready, run before it is marked ready when made; the checks wait keeps watching while a required check has not posted | `bin/fm-dod-lib.sh` (`fm_dod_block` direct-PR text, `fm_dod_checks_green_block`), `tests/fm-dod-lib.test.sh` | same files | carried | 427056c4 |
