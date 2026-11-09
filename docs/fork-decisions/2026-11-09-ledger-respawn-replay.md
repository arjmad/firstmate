2026-11-09: the 2026-11-08 firstmate operations audit (ops audit 1109, fix 10), run on Arjun's request to make the ecosystem optimal, found 1,717 of a week's 3,920 ledger status rows were replays of the persistent second mate's status log.
Decision: a second mate's respawn keeps its status log's ledger offset, and capture records a stamped status line once per task.
Why: every second mate respawn records a fresh dispatch, and that dispatch deleted the byte offset, so the next capture recorded the whole log again and every ledger count overstated that second mate about four times.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `dispatched` deletes a leftover offset only while the task has no status log | `bin/fm-fleet-ledger.sh` (`dispatched`, header), `tests/fm-fleet-ledger.test.sh`, `docs/fleet-ledger.md` "Events" | `bin/fm-fleet-ledger.sh`, `tests/fm-fleet-ledger.test.sh`, `docs/fleet-ledger.md` | carried | 45dd50a5 |
| `task.status` records carry the line's `at` stamp, and capture skips a stamped line whose `at`, `state`, `key`, and `text` are already recorded for the task | `bin/fm-fleet-ledger.sh` (`record`, `load_recorded_keys`, `append_status`, `capture_task`), `tests/fm-fleet-ledger.test.sh`, `docs/fleet-ledger.md` "Events" and "Limits" | `bin/fm-fleet-ledger.sh`, `tests/fm-fleet-ledger.test.sh`, `docs/fleet-ledger.md` | carried | 45dd50a5 |
