2026-10-26: Arjun asked in the helm for the lasting fix to firstmate PRs conflicting over `docs/fork-decisions.md` ("yes we want to make whatever changes are optimal"), after PRs 115-118 each conflicted once another merged, because every PR appended a row to that one table and #114's `merge=union` applies only to a local merge or rebase, never to GitHub's server-side merge.
Decision: each fork decision and each fork patch is its own file under `docs/fork-decisions/`, named `<YYYY-MM-DD>-<slug>.md`, and `docs/fork-decisions.md` is a stable entry point holding the layout and the fork-patch contract and no records, so dated references to it still resolve.
A new record names no PR number: `bin/fm-fork-decisions.sh patches` reads it from the squash commit that added the file, so no follow-up commit backfills one.
`bin/fm-fork-decisions.sh check` fails when a decision or row is added to the entry point, through `tests/fm-fork-decisions.test.sh` in CI, and the `merge=union` line is gone because nothing appends to a shared file any more.
The documentation audience inventory classifies the directory with one entry ending in `/`, so a new record needs no inventory edit either.
No upstream proposal.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| One file per fork decision or fork patch, checked and listed by `fm-fork-decisions.sh` | `bin/fm-fork-decisions.sh`, `tests/fm-fork-decisions.test.sh`, `docs/fork-decisions.md`, `docs/fork-decisions/` | `bin/fm-test-run.sh` (family, changed-path, serial hint), `docs/scripts.md`, `bootstrap-diagnostics` skill | carried | 45dd50a5 |
| A documentation inventory surface ending in `/` classifies every tracked prose file under that directory | `bin/fm-doc-audience-check.sh` (`validate`, header), `tests/fm-documentation-audiences.test.sh` | same files, `docs/documentation-audiences.json`, `docs/documentation-audiences.md` | carried | 45dd50a5 |
