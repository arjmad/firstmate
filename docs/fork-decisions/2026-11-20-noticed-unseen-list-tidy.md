2026-11-20: Arjun approved audit finding a7-18 in his deep-audit helm walk: the noticed unseen list on Heimdall held 277 lines, 49 of them halves of titles split by tasks-axi's truncation pointer, and 164 of its 166 `noticed` entries named rows already closed.
Decision: `close` stores the full title, and `unseen` drops a `noticed` entry once its row is closed by any path and rejoins titles an older `close` split.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `close` reads the title with `show --full`, and `unseen` rewrites the list under its lock: a `noticed` entry whose row is no longer queued or in flight leaves it, a split title is rejoined with `...`, and a failed backlog read prunes nothing | `bin/fm-noticed.sh` (`cmd_close`, `cmd_unseen`, `tidy_unseen`, `open_row_ids`), `tests/fm-noticed.test.sh` | none (fork-only script) | carried | 9ac0288e |
