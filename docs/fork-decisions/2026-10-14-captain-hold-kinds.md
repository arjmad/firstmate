PR: #82

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Captain-hold kinds (`--kind` reversible or arjun-only) | `bin/fm-captain-hold.sh` (`hold`), `bin/fm-hold-reason-lib.sh` (`fm_hold_reason_decode`), `tests/fm-captain-hold-kind.test.sh` | `bin/fm-captain-hold.sh`, `.agents/skills/captain-hold-lifecycle`, `docs/captain-hold-lifecycle.md` | conflicted | 45dd50a5 |
| A reversible `--default` that releases itself after 72 hours as the decision of record, and the watcher's hourly `release-due` tick; [removed 2026-11-01](2026-11-01-drop-default-release.md) | `bin/fm-captain-hold.sh` (`release-due`), `bin/fm-watch.sh` (`hold_release_tick`), `tests/fm-captain-hold-kind.test.sh` | `bin/fm-watch.sh`, `docs/configuration.md`, `tests/fm-watch-triage.test.sh` | superseded by #161 | 45dd50a5 |
