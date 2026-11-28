PR: #95

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Outside local-only mode, teardown refuses until the delivery PR (the recorded `pr=`, a companion's `also_pr_<repo>=`, or else the branch's newest GitHub PR) is merged with the current work, even on a pushed branch; a closed or unreadable PR passes only when its content is in the default branch, and each read is bounded by `FM_TEARDOWN_PR_READ_TIMEOUT` | `bin/fm-teardown.sh` (the delivery-PR check), `tests/fm-teardown.test.sh` (q6 to q10) | `bin/fm-teardown.sh`, `tests/fm-teardown.test.sh` | carried | 9ac0288e |
