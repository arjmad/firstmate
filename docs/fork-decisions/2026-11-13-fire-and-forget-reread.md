PR: #249

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A fire-and-forget steer whose ring did not land says it waits for the next ring or the agent's own inbox check, instead of promising a re-ring the ladder never makes | `bin/fm-send.sh` (`ring_retry`), `tests/fm-send-inbox.test.sh` | `bin/fm-send.sh` | carried | 427056c4 |
