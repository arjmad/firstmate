2026-11-20: Arjun approved audit finding a7-04 in his deep-audit helm walk: the overdue backstop fired once per gate and then went silent, so a row whose one wake was acknowledged without a re-date or dispatch stayed quiet for days.
Decision: a row still overdue wakes again each week until it is dispatched, re-dated, answered, or closed.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The overdue marker records its gate date and wake time, and a row still overdue 7 days after its wake (`FM_BACKLOG_OVERDUE_REFIRE_SECS`) wakes again; a date-only marker from before wakes once more | `bin/fm-backlog-overdue.sh` (`cmd_scan`), `bin/fm-watch.sh` (comments), `docs/task-lifecycle.md`, `docs/configuration.md`, `docs/scripts.md`, `tests/fm-backlog-overdue.test.sh` | `bin/fm-watch.sh`, `docs/configuration.md`, `docs/scripts.md` | carried | 427056c4 |
