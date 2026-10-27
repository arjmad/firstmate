PR: #87

2026-10-27: The captain asked, from Claude Code on Thor, for plain session names: the helm `firstmate`, a secondmate its id such as `secondmate`, and a worker its task id.
That replaced this record's original `<kind>: <task-id>` form; `bin/fm-progress.sh` still matches the old form so a worker launched before the change keeps its steps.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Name every Claude launch after its bare task id (a secondmate its own id, the helm `firstmate` in README's launch command) with `--name`, so workers stop sharing the doorbell auto-title "Firstmate operational inbox message" in the Claude app, Remote Control, and `/resume` | `bin/fm-spawn.sh` (`claude_session_name_flag`, `__CLAUDENAME__`), `bin/fm-progress.sh` (worker session lookup by name), `README.md` (Claude Code launch), `tests/fm-spawn-dispatch-profile.test.sh` (`test_claude_launch_names_the_session_after_its_task`) | `bin/fm-spawn.sh` (`launch_template` claude case), `bin/fm-progress.sh`, `README.md`, `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-secondmate-harness.test.sh`, `tests/fm-control-relaunch.test.sh`, `tests/fm-progress.test.sh`, `harness-adapters` Claude reference, `docs/verification/runtime-backends.md` | carried | 45dd50a5 |
