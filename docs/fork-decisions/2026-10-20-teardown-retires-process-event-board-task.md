PR: #94

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Teardown retires every process-event board the task owns through the new `retire-task` command, acknowledging a silent round first and keeping (and naming) a board whose round still carries content; once the owner has neither record nor status log its rounds go to firstmate as `check` wakes and reconcile retires the board | `bin/fm-procevent.sh` (`cmd_retire_task`, `owner_task_gone`, `source_pending` exact match, `publish_result`, `cmd_reconcile`), `bin/fm-teardown.sh` (board retirement once the task record is removed), `tests/fm-procevent.test.sh`, `tests/fm-teardown.test.sh` (`test_teardown_retires_the_task_owned_boards`) | `bin/fm-procevent.sh`, `bin/fm-teardown.sh`, `docs/configuration.md`, `.agents/skills/process-event-sources/SKILL.md` | carried | 45dd50a5 |
