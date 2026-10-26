PR: #107

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Claude ship and scout launches set `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` so the task list exists, and ship and scout briefs ask the worker to keep its plan there | `bin/fm-spawn.sh` (`launch_template` claude case), `bin/fm-brief.sh` (`PLAN_LINE`), `tests/fm-spawn-dispatch-profile.test.sh` (`test_claude_task_workers_launch_with_the_task_list`), `tests/fm-brief.test.sh` (`test_workers_keep_their_plan_as_steps`) | `bin/fm-spawn.sh` (`launch_template` claude case), `bin/fm-brief.sh` (rule 4 of ship and scout briefs), `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-backend-orca.test.sh`, `harness-adapters` Claude reference | carried | 45dd50a5 |
