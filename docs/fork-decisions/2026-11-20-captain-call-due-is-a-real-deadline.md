2026-11-20: Arjun approved audit finding a7-02 in his deep-audit helm walk: every new captain call got an invented next-day `Due:` line, so 37 of 42 overdue-looking queued rows on 2026-11-19 were default dates and the real deadlines could not be told apart.
Decision: a `Due:` line means only an outside deadline; a new call filed without `--until` stays live with no `Due:` line, and the helm clears the default dates already written.
This supersedes the captain exception of `2026-11-08-backlog-row-shape.md` and its next-day `Due:` row.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `hold` records a `Due:` line only from `--due`; the next-day default and `captain_call_default_due` are gone, `write_due` becomes `write_row_field`, and the wrapper's dateless captain-hold refusal names the hold helper without promising a date | `bin/fm-captain-hold.sh` (`command_hold`, `write_row_field`), `bin/fm-tasks-axi.sh` (`guard_row_shape` message, header), `docs/task-lifecycle.md` "Backlog contract", `tests/fm-captain-hold-kind.test.sh` | `bin/fm-captain-hold.sh`, `bin/fm-tasks-axi.sh`, `docs/task-lifecycle.md` | carried | 427056c4 |
