2026-11-08: Arjun picked "Both: board, then count line" in a helm grill about the long held group in the startup digest, then widened it the same day ("adopt") to a count per month with due dates and hold dates shown.
Decision: the session-start backlog section prints in full every in-flight, ready, and blocked row, every undated hold, and every held row whose back-on date - `hold_until`, else a leading `[YYYY-MM-DD]` title date - is within 7 days or whose `Due: YYYY-MM-DD` body line is within 14 days.
Every held row it prints shows its `hold_until`.
Every later unblocked queued held row folds into one `parked until <YYYY-MM>: <N> held rows` line per month of its back-on date, naming `bin/fm-tasks-axi.sh ready --include-held`, which lists them.
The digest reads the due line from the backlog file itself, because `tasks-axi list` cuts bodies at 500 characters; it tolerates the line's absence and prints no body.
This applies to the tasks-axi listing; the title-line fallback for a manual or unavailable backend is unchanged.
The read-once startup and OPEN DECISIONS shapes are unchanged.
Why: rows that cannot act this week cost every startup read their full text, so the digest keeps only a count per month and the command that lists them, while anything due soon stays in view.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The held group asks for `hold_until`, keeps it on every printed row, reads `Due:` lines from the backlog file, and folds later unblocked queued held rows not due within 14 days into one count line per month | `bin/fm-session-start.sh` (`FAR_HOLD_DAYS`, `DUE_SOON_DAYS`, `date_in_days`, `backlog_due_dates`, `print_held_far_folded`, `print_backlog_tasks_axi_compact`, BACKLOG DIGEST header), `tests/fm-session-start.test.sh` (`make_fake_tasks_axi_compact`, `test_backlog_held_far_gated_rows_fold_into_one_count_line_per_month`), `docs/configuration.md` (`FM_SESSION_START_QUEUED_LIMIT` comment) | `bin/fm-session-start.sh`, `tests/fm-session-start.test.sh`, `docs/configuration.md` | superseded by the [2026-11-12 lean re-entry record](2026-11-12-lean-reentry-digest.md) | c8d8fdad |
| The reason round-trip fixture's dated captain call comes back in 3 days, so the startup digest still lists it in full | `tests/fm-captain-hold-lifecycle.test.sh` (`sample-dated-call`) | `tests/fm-captain-hold-lifecycle.test.sh` | carried | c8d8fdad |
