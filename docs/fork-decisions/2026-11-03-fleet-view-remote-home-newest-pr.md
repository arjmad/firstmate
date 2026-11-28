PR: #162

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The fleet view labels a remote secondmate home as remote and not checked, and a secondmate's status PR is its newest one rather than its first | `bin/fm-fleet-snapshot.sh` (`last_pr_url_in_file`, `task_json_row`), `bin/fm-fleet-view.sh`, `tests/fm-fleet-snapshot-view.test.sh` | `bin/fm-fleet-snapshot.sh`, `bin/fm-fleet-view.sh` | carried | 9ac0288e |
