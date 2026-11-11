PR: #165

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The watcher checkpoint is bounded by `fm_exec_timed`, whose new `FM_EXEC_TIMED_SIGNAL` names the bound signal, rather than `timeout --signal=INT`, which uutils KILLs at once | `bin/fm-watch-checkpoint.sh` (`run_bounded`), `bin/fm-timeout-lib.sh` (`fm_exec_timed`), `tests/fm-timeout-lib.test.sh`, `tests/fm-watch-checkpoint.test.sh` | `bin/fm-watch-checkpoint.sh`, `bin/fm-timeout-lib.sh`, `tests/fm-timeout-lib.test.sh`, `tests/fm-watch-checkpoint.test.sh` | conflicted | c8d8fdad |
| A remote job sequence claim is won by an exclusive `.claimed` marker inside the claim directory, because a uutils `mkdir` race lets two claimants both succeed, and the reaper removes the markers before its batched `rmdir` | `bin/fm-remote-job-lib.sh` (`fm_remote_job_next_seq`, claim reaper), `tests/fm-remote-transport-lanes.test.sh` | `bin/fm-remote-job-lib.sh` | carried | c8d8fdad |
| The public follow-up closed-stdout case runs its poll through `bash`, because a uutils `env` reopens a closed stdout as `/dev/null` | `tests/fm-public-followup.test.sh` | same test | carried | c8d8fdad |
