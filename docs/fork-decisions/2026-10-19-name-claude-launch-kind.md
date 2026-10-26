PR: #87

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Name every Claude launch `<kind>: <task-id>` with `--name`, so workers stop sharing the doorbell auto-title "Firstmate operational inbox message" in the Claude app, Remote Control, and `/resume` | `bin/fm-spawn.sh` (`claude_session_name_flag`, `__CLAUDENAME__`), `tests/fm-spawn-dispatch-profile.test.sh` (`test_claude_launch_names_the_session_after_its_task`) | `bin/fm-spawn.sh` (`launch_template` claude case), `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-secondmate-harness.test.sh`, `tests/fm-control-relaunch.test.sh`, `harness-adapters` Claude reference, `docs/verification/runtime-backends.md` | carried | 45dd50a5 |
