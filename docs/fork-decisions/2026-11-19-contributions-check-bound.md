PR: #275

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The contributions check fits inside the watcher's per-check bound: one `find` reads every record's size, the forge deadline counts from the script's launch less the watcher's margin, and each poll first replays saved signals a crash left unqueued | `bin/fm-contributions.sh` (header, `oversized_records`, forge deadline, `replay_unnotified`, `poll`), `tests/fm-contributions.test.sh` | `bin/fm-contributions.sh` | carried | 9ac0288e |
