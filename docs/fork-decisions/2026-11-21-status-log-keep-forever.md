2026-11-21: Arjun's D5 rule for task folders, recorded in the [task text record](2026-11-21-task-text-kept-media-swept.md), is to keep the text of every task forever.
Decision: teardown's status-archive prune no longer deletes archived `data/<id>/status.log` or `status.<N>.log` files, in the task folder or under `children/`, at any age.
It diverges from upstream, which prunes those logs after 30 days, because that prune deleted task text before the off-site text backup could keep it.
Orphaned `.status-archive.*` staging files older than 30 days are still pruned, because they are partial publication leftovers, not task text.
A keep switch was not added: no upstream contract depends on the logs being pruned, so dropping the prune is the smaller change.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Keep archived status logs at every age; prune only stale `.status-archive.*` staging files | `bin/fm-teardown.sh` (header, `teardown_prune_status_archives`), `tests/fm-teardown.test.sh` (`test_status_archive_reuse_and_retention`), `docs/configuration.md` (Task status archive, record export), `bin/fm-data-media-prune.sh` (header), `bin/fm-record-hygiene-lib.sh` (archive comment) | `bin/fm-teardown.sh`, `tests/fm-teardown.test.sh`, `docs/configuration.md` | carried | 427056c4 |
