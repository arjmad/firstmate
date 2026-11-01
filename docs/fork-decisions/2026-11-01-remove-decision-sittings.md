2026-11-01: Arjun reversed the [decision sittings](2026-11-01-decision-sittings.md) the day they landed, in the helm: "no remove the 12/20 boards just alert me right away".
Decision: every captain call reaches him at once, as before the sittings; there are no 12:00 or 20:00 sitting boards, and a call's hold kind no longer decides when it is brought to him.
The [scout release at report time](2026-11-01-scout-release.md) from the same board stays: a scout still ends at its report, firstmate holds its open call bound to the board, and the answer starts a fresh ship.
A home that ran the sittings may still hold a call that waited for one, so its watcher wakes firstmate once to bring every live call to him and clears the sitting state.
No upstream proposal: the sittings were this fork's own patch, and removing them restores upstream's text.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The watcher finds state the retired sittings left in a home, queues one durable `check: decision sittings retired` wake when a call could have been held for a sitting, and removes that state, so held calls reach the captain now and the wake fires once | `bin/fm-watch.sh` (`decision_sittings_retire_tick`), `tests/fm-watch-triage-wait.test.sh` | watcher main loop (one added tick call) | carried | 45dd50a5 |
