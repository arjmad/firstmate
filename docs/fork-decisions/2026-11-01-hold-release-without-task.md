2026-11-01: Firstmate decided, on a bug noticed in the review of the decision-sittings removal, to make a reversible hold's 72-hour default release fire in a home with no live task.
Decision: a waiting default counts as supervision need, so the watcher whose hourly tick runs `release-due` keeps running after the last task is torn down.
Why: scout release at report time tears the scout down and leaves its open call as a captain hold, and with no task and no watcher that call's default never released on its own.
No new scheduler: the existing watcher tick still does the release, and only the supervision predicate learns about the wait.
No upstream proposal: hold kinds and default release are this fork's own patch (2026-10-14).
Superseded the same day: Arjun [dropped the default release](2026-11-01-drop-default-release.md), so no default waits to keep a home supervised.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `hold` writes `state/.hold-release-pending` when it records a default, and `release-due` keeps it while a default still waits and clears it by token otherwise | `bin/fm-captain-hold.sh` (`command_hold`, `command_release_due`, `hold_default_due`, `set_hold_release_marker`, `clear_hold_release_marker`), `tests/fm-captain-hold-kind.test.sh`, `docs/captain-hold-lifecycle.md`, `docs/configuration.md` | none (fork-owned hold-kind code) | superseded by #PRNUM | 45dd50a5 |
| The supervision predicate counts that marker as need, and both guards name it in their watcher-down banners | `bin/fm-supervision-lib.sh` (`fm_supervision_status`, `FM_SUP_HOLD_RELEASE`), `bin/fm-guard.sh`, `bin/fm-turnend-guard.sh` (`block_stop`, terminal notice), `tests/fm-turnend-guard.test.sh`, `docs/turnend-guard.md` | supervision need predicate and the guard need banners | superseded by #PRNUM | 45dd50a5 |
