PR: #246

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A doorbell ring whose submit returns unknown, pending, or pending-unproven reports a distinct unconfirmed outcome (return 4): `fm-send` and the remote leg say the turn start is unconfirmed, and a fire-and-forget record is owed its one retry | `bin/fm-task-inbox-lib.sh` (`fm_task_inbox_ring`), `bin/fm-send.sh`, `bin/fm-remote-secondmate-control.sh`, `bin/fm-watch.sh`, `docs/configuration.md`, `docs/remote-secondmates.md`, `tests/fm-task-inbox.test.sh`, `tests/fm-send-inbox.test.sh`, `tests/fm-send-remote-delivery.test.sh`, `tests/fm-backend-herdr.test.sh`, `tests/fm-backend-t3code.test.sh` | the same files | carried | 9ac0288e |
