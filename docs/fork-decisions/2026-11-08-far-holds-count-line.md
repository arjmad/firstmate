2026-11-08: Arjun picked "Both: board, then count line" in a helm grill about the long held group in the startup digest.
Decision: the session-start backlog section prints the unblocked queued held rows whose gate - `hold_until`, else a leading `[YYYY-MM-DD]` title date - is more than 7 days out as one `parked until later:` count line naming `bin/fm-tasks-axi.sh ready --include-held`, which lists them.
Rows gated within 7 days, undated captain holds, and every in-flight, blocked, and ready row print exactly as before, and the read-once startup and OPEN DECISIONS shapes are unchanged.
Why: rows that cannot act this week cost every startup read their full text, so the digest keeps only their count and the command that lists them.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The held group asks for `hold_until`, folds far-gated unblocked queued rows into one count line, and strips the column from every kept row and the header | `bin/fm-session-start.sh` (`FAR_HOLD_DAYS`, `far_hold_horizon`, `print_held_far_folded`, `print_backlog_tasks_axi_compact`, BACKLOG DIGEST header), `tests/fm-session-start.test.sh` (`make_fake_tasks_axi_compact`, `test_backlog_held_far_gated_rows_fold_into_one_count_line`), `docs/configuration.md` (`FM_SESSION_START_QUEUED_LIMIT` comment) | `bin/fm-session-start.sh`, `tests/fm-session-start.test.sh`, `docs/configuration.md` | carried | 45dd50a5 |
