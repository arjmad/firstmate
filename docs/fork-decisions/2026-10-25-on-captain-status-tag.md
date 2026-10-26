PR: #109

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A worker blocked on the captain says so with the structured `[on=captain]` status tag, read by `status_open_captain_waits` into the fleet snapshot's `hints.captain_waits` and the bearings snapshot's `waits_on`/`since`; `--fields board` adds full titles, waits and `ready` for the board composer | `bin/fm-classify-lib.sh`, `bin/fm-fleet-snapshot.sh`, `bin/fm-bearings-snapshot.sh`, `bin/fm-brief.sh`, `tests/fm-classify-decision-key.test.sh`, `tests/fm-bearings-snapshot.test.sh` | same files | carried | 45dd50a5 |
