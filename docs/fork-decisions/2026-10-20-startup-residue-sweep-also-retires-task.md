PR: #94

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The startup residue sweep also retires task-keyed records (`.seen-*`, `.hb-surfaced-*`, branch-outcome caches) of tasks nothing live references, surfaced process-event markers with nothing behind them, dead lock owners, and orphaned home-summary scratch | `bin/fm-state-residue-sweep.sh` (`sweep_task_records`, `sweep_lock_owners`), `bin/fm-wake-lib.sh` (`fm_wake_procevent_marker_path`, `FM_LOCK_KNOWN_FILES`), `bin/fm-branch-outcome.sh` (`rebuild_outcome_indexes` skips retired tasks), `tests/fm-state-residue-sweep.test.sh`, `tests/fm-branch-supervision.test.sh` | `bin/fm-state-residue-sweep.sh`, `bin/fm-watch.sh` (`procevent_surfaced_marker`), `bin/fm-branch-outcome.sh`, `tests/fm-state-residue-sweep.test.sh`, `docs/scripts.md` | carried | 45dd50a5 |
