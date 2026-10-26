# Fork decisions

This fork's standing decisions and its fork patches live one record per file under [`docs/fork-decisions/`](fork-decisions/), and this page is their stable entry point.
It holds no records, so no PR edits it to record one, and two PRs that each record a decision never touch the same file.
`bin/fm-fork-decisions.sh check` fails when a dated decision or a table row is added here, and `tests/fm-fork-decisions.test.sh` runs it in CI.

## Finding a record

A record is `docs/fork-decisions/<YYYY-MM-DD>-<slug>.md`, dated the day of the decision or patch.
A reference written `docs/fork-decisions.md <date>`, or "fork decision <date>", names that date's records; a reference that names a topic, such as "pool-slot allocation records row", names the record whose slug carries that topic.
`ls docs/fork-decisions/` lists them oldest first, and `bin/fm-fork-decisions.sh patches` prints every fork-patch row as one table with its date and PR.

## Record format

A decision opens with `<date>: ` and says who decided, where, what was decided, and why, one sentence per line.
A fork patch holds one table whose header is `| What | Files or functions | Upstream code touched | Status | Last checked sync |`, with one row per change; rows that repeat one `What` spread a single change across files.
A record may hold both, the decision first.
A new record names no PR number: the squash commit that adds the file ends in `(#N)`, and `bin/fm-fork-decisions.sh patches` reads the number from there, so no follow-up commit backfills one.
The records migrated from the earlier single table open with a `PR: ` line instead, because the migration commit added their files; a PR value without a number names the commit.
A later decision that changes an earlier one edits that record or adds a new dated record naming the one it supersedes.

## Fork patches

The [decision to keep firstmate fixes in this fork](fork-decisions/2026-10-10-fork-patches-stay-in-fork.md) is why fork patches are tracked.

Contract:
Every fork PR that changes upstream-owned files adds one fork-patch record naming what changed, where, and the upstream code it touches.
Every upstream-sync PR re-checks each row `bin/fm-fork-decisions.sh patches` lists against the merged upstream and updates its status and last-checked sync in its record.
Status is `carried` when the change still applies and upstream is unchanged there, `upstreamed` when upstream now has an equivalent so the fork change can be dropped at the next sync, or `conflicted` when upstream changed the same code and the merge needed a hand.
A sync drops a fork change only when its row reads `upstreamed`, and the captain's merge of that sync PR is the approval.
A sync PR lands as a merge commit, never a squash, so the next sync's merge base is the upstream commit it merged.
The 2026-10-14 sync (#81) landed squashed, which left git's merge base at 1a868710, so the 2026-10-19 sync merged against 24f3a6b8 explicitly.

The first records cover the fork-only commits in `git log --no-merges upstream/main..origin/main` at upstream `main` 1a868710, grouped by change.
The upstream-merge commits (95b30d7d, #21, #34) and the fork-decisions-only docs commits (#66, #67, #71) are syncs or fork-owned prose and carry no record.
