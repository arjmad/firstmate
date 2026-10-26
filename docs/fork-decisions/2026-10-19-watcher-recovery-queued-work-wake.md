PR: #90

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A watcher recovery that carries queued work (often an inbox note or a merge outcome another process appended) reads `check: queued work: <count> <kind>, ...` instead of the generic `check: rearm-resurface`, so it no longer reads as watcher downtime; it counts main's rows by kind and never quotes a payload; routing is unchanged | `bin/fm-watch.sh` (`resurface_reason`, `WATCHER_RESURFACED`), `tests/fm-watch-arm.test.sh` (`test_recovery_names_queued_work`) | `bin/fm-watch.sh` (`resurface_after_downtime`, `watcher_cleanup`), `docs/watcher-continuity.md`, `tests/fm-watch-arm.test.sh`, `tests/fm-watch-checkpoint.test.sh`, `tests/fm-watch-recovery-loop.test.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-pr-check-security.test.sh`, `tests/fm-supervision-host.test.sh` | carried | 45dd50a5 |
