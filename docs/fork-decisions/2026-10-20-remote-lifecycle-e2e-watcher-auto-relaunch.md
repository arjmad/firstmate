PR: #93

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The remote lifecycle e2e watcher auto-relaunch leg waits past the watcher's own 120 s per-relaunch bound instead of a fixed ~30 s, because the relaunch is a whole remote spawn that measured 27-35 s on CI and flaked portable serial 4 | `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` (watcher liveness leg) | same test | carried | 45dd50a5 |
