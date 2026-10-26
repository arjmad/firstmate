PR: #96

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A live checkout held only by uncommitted edits under its `capture=<dir>/` starts that entry's capture command detached, once per edit state, and reports `capturing:` instead of `STUCK:` until a finished capture leaves it stuck | `bin/fm-fleet-sync.sh` (`capture_or_report_stuck`, `capture_paths_only`, `capture_fingerprint`, the `capture=` token in `sync_live_checkouts`), `tests/fm-fleet-sync.test.sh` (`test_capture_*`) | `bin/fm-fleet-sync.sh` (`report_stuck`, `fast_forward_clone`'s dirty branch), `docs/configuration.md` | carried | 45dd50a5 |
