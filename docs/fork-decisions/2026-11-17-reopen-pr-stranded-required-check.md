PR: #259

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The direct-PR checks-wait step tells a worker to close and reopen a PR whose required check's Actions run stays `queued` with no jobs for over 10 minutes, as after a GitHub Actions outage | `bin/fm-dod-lib.sh` (`fm_dod_checks_green_block`), `tests/fm-dod-lib.test.sh` | `bin/fm-dod-lib.sh` | carried | 9ac0288e |
