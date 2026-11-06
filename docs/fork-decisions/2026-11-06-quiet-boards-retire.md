2026-11-06: Arjun picked "Retire after 14 quiet days or when the task closes" on the runtime-audit board card board-retire, after the 2026-11-05 audit on Heimdall found 37 live board listeners, 22 of them adopted from finished tasks and the oldest from October 7.
Decision: firstmate retires a Lavish board it owns or adopted once it has had no round for 14 days, or, for an adopted board, once every backlog row carrying it has closed, accepting that a very late answer on a retired board no longer arrives.
The sweep runs from the watcher's existing reconcile cycle, never touches a board a live task hosts, and logs each retirement in one line.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Reconcile retires quiet or concluded firstmate-owned and adopted Lavish boards on its own cadence | `bin/fm-procevent.sh` (`retire-quiet-boards`, `board_last_round`, `board_rows_closed`, `board_sweep_due`, `cmd_reconcile`), `tests/fm-procevent-board-retire.test.sh`, `bin/fm-test-run.sh` (changed-file map), `docs/configuration.md` "Retire quiet and concluded boards", `.agents/skills/process-event-sources/SKILL.md`, `.agents/skills/bearings/SKILL.md` | `bin/fm-procevent.sh`, `bin/fm-test-run.sh`, `docs/configuration.md`, `.agents/skills/process-event-sources/SKILL.md`, `.agents/skills/bearings/SKILL.md` | carried | 45dd50a5 |
