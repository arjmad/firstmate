PR: #92

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Every task-record writer goes through `fm_pr_meta_rewrite`, which keeps the `pr=` identity block last and repairs a record an earlier writer left with keys after it, so a relaunch, a captain-hold attestation, or a `review=` line never breaks the PR merge watch | `bin/fm-pr-lib.sh` (`fm_pr_meta_rewrite`), `bin/fm-spawn.sh` (relaunch, traceparent and polytoken rewrites), `bin/fm-captain-hold.sh` (attestation), `bin/fm-review-check.sh`, `tests/fm-control-relaunch.test.sh`, `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-pr-check-security.test.sh` | `bin/fm-spawn.sh` (`spawn_meta_rewrite_before_pr`, which the fork drops for `fm_pr_meta_rewrite`), `bin/fm-pr-lib.sh` | conflicted | 9ac0288e |
