PR: #82

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Captain-hold kinds (`--kind` reversible or arjun-only), a reversible `--default` that releases itself after 72 hours as the decision of record, and the watcher's hourly `release-due` tick; the default release and its tick were removed by the [2026-11-01 drop-default-release record](2026-11-01-drop-default-release.md), and the kinds stay | `bin/fm-captain-hold.sh` (`hold`, `release-due`), `bin/fm-hold-reason-lib.sh` (`fm_hold_reason_decode`), `bin/fm-watch.sh` (`hold_release_tick`), `tests/fm-captain-hold-kind.test.sh` | `bin/fm-captain-hold.sh`, `bin/fm-watch.sh`, `.agents/skills/captain-hold-lifecycle`, `docs/captain-hold-lifecycle.md`, `docs/configuration.md`, `tests/fm-watch-triage.test.sh` | conflicted | 45dd50a5 |
