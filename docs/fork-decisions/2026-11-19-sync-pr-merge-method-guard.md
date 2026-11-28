2026-11-19: Arjun chose, at the helm, to stop upstream syncs landing squashed ("A": the ancestry PR, the merge-method guard and the missing records).
The 2026-09-17 (#21), 2026-10-14 (#81) and 2026-11-16 (#256) syncs each landed as a squash, because `bin/fm-pr-merge.sh` squashes when no method is named, so git lost the upstream commit's ancestry and `fleet-updates` reported the fork behind upstream when it was not.
Decision: on GitHub, `bin/fm-pr-merge.sh` refuses a squash or rebase, the implicit default included, of a pull request whose verified head merged in a lineage its base branch lacks, and names `-- --merge` as the fix.
The check reads the pull request's commits from GitHub's compare API rather than a local `upstream` remote, because the merging clone may have none.
A pull request that merged another unlanded feature branch is refused the same way, because a squash would also swallow that branch's commits.
The guard reads parent order, so it catches a sync built the documented way, upstream merged into a branch cut from `main`; a sync built the other way round looks exactly like GitHub's own update-branch merge and is not caught.
No upstream proposal: the guard serves this fork's sync workflow.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Refuse to squash or rebase an upstream-sync pull request on GitHub, naming `-- --merge` | `bin/fm-pr-merge.sh` (header, GitHub gate loop), `tests/fm-pr-merge.test.sh` (gh mock compare answers, `add_revert_repo` sync fixtures), `tests/fm-pr-check-security.test.sh` and `tests/fm-captain-hold-lifecycle.test.sh` (their gh mocks answer the paged compare read) | `bin/fm-pr-merge.sh` (the default `--squash`), `tests/fm-pr-merge.test.sh`, `tests/fm-pr-check-security.test.sh`, `tests/fm-captain-hold-lifecycle.test.sh` (gh mocks) | conflicted | 9ac0288e |
