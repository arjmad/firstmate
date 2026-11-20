2026-11-20: Arjun approved audit finding a7-04 in his deep-audit helm walk: the overdue backstop fired once per gate and then went silent, so a row whose one wake was acknowledged without a re-date or dispatch stayed quiet for days.
Decision: a row still overdue wakes again each week until it is dispatched, re-dated, answered, or closed; this supersedes the once-per-gate row of `2026-10-28-agents-md-byte-budget-overdue-backlog-wake.md`.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The overdue marker records its gate date and wake time, and a row still overdue 7 days (`FM_BACKLOG_OVERDUE_REFIRE_SECS`) after its wake was handled wakes again, naming its cadence (`0` or `off` keeps one wake per gate), decided under the wake-queue lock; a date-only marker from before wakes once more | `bin/fm-backlog-overdue.sh` (`cmd_scan`), `bin/fm-watch.sh` (comments), `docs/task-lifecycle.md`, `docs/configuration.md`, `docs/scripts.md`, `tests/fm-backlog-overdue.test.sh` | `bin/fm-watch.sh`, `docs/configuration.md`, `docs/scripts.md` | carried | 427056c4 |
