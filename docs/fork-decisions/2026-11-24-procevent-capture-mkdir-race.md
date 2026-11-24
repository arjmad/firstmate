| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A process-event runner whose capture inbox or reservation `mkdir` loses to another source's runner still captures, because the private-directory validation, not the `mkdir` status, decides whether the directory is usable | `bin/fm-procevent-lib.sh` (`fm_procevent_capture_inbox_prepare`, `fm_procevent_capture_reservation_prepare`), `tests/fm-procevent.test.sh` (the peer-runner preparer case) | `bin/fm-procevent-lib.sh`, `tests/fm-procevent.test.sh` | carried | 427056c4 |
