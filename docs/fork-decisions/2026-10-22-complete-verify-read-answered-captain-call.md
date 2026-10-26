PR: #98

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `complete` and `verify` read an answered captain call that done_keep retention moved into the markdown archive, from the newest archived copy of its row, instead of reporting it absent | `bin/fm-captain-hold.sh` (`archived_task_show`, `task_show_or_archived`, the archive step of `resolve_entry`, `verify_hold_durable`), `tests/fm-captain-hold-lifecycle.test.sh` | same files | carried | 45dd50a5 |
