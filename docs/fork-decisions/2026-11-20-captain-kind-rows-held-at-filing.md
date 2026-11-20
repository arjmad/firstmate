2026-11-20: Arjun approved audit finding a7-21 in his deep-audit helm walk: the responder files a step only he can take (`kind captain`, `Owner: arjun`) through `bin/fm-tasks-axi.sh add` with no hold, so the row sat in the dispatchable ready group instead of among his calls.
Decision: firstmate's wrapper holds such a row for him at filing, so no caller has to remember the hold and every hold-based view (calls, the Monday "Waiting 2+ weeks" list, Launchpad) sees it.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `add` of a `--kind captain` row owned by `arjun` holds a new or already-present open, unheld row through `bin/fm-captain-hold.sh hold`, and fails with exit 1 when the hold cannot be written | `bin/fm-tasks-axi.sh` (`hold_added_captain_row`), `tests/fm-tasks-axi.test.sh` | `bin/fm-tasks-axi.sh` | carried | 427056c4 |
