PR: #271

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The bootstrap suite's missing-session-CLI case runs on a `PATH` built with `fm_test_base_path_sans`, so a host that installs herdr or another session CLI system-wide still sees it missing | `tests/fm-bootstrap.test.sh` | `tests/fm-bootstrap.test.sh` | carried | 427056c4 |
