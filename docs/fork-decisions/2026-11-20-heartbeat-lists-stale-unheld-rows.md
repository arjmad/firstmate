2026-11-20: Arjun approved audit finding a7-17 in his deep-audit helm walk: approved helm-side rows sat queued, unheld and unclaimed for 8-9 days because nothing listed them as something to act on.
Decision: the fleet view the heartbeat review reads lists each unheld ready row older than 7 days as an action, and the helm dates or dispatches the rows already waiting.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A "Waiting Unheld" section lists every queued row with no hold, no unresolved blocker, and a `since` date 7 or more days (`FM_FLEET_VIEW_UNHELD_DAYS`) before the snapshot's date, with its action: hold a captain-owned row for him, else dispatch, date or close it | `bin/fm-fleet-view.sh`, `tests/fm-fleet-snapshot-view.test.sh` | `bin/fm-fleet-view.sh`, `tests/fm-fleet-snapshot-view.test.sh` | carried | 427056c4 |
