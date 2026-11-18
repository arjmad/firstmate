2026-11-18: Arjun's 2026-11-11 rule for noticed rows had a worker fix the data retention prune that PR 262 left as the last history-scaled step on the session-start blocking path, about 11s at load 28 on Heimdall, whose `data/` is over the size trigger.
Decision: the bootstrap runs the media and scratch retention parts at most once every 12 hours, because retention counts whole days, and a real run reuses each large task's size line while that task's size is unchanged, so the prune stays synchronous without the task-set lock and most session starts pay only its `du` of `data/` and the backlog read.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `--if-due` skips the media and scratch retention parts when `state/.data-retention-last` records a real retention run within 12 hours, and the size trigger reuses a task's line from `state/.data-size-cache` while that task's KiB is unchanged; the bootstrap passes `--if-due` | `bin/fm-data-media-prune.sh`, `tests/fm-data-media-prune.test.sh` | `bin/fm-bootstrap.sh` (header, data media prune call), `docs/configuration.md` | carried | 427056c4 |
