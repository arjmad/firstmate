PR: #82

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Dependent-repository companion worktrees: `--also <repo>` on the brief and spawn, companion PRs recorded and merged under the same task, companion slots checked and returned at teardown | `bin/fm-brief.sh` (`--also`), `bin/fm-spawn.sh` (`spawn_take_companion_slot`, `spawn_list_companion_worktrees`), `bin/fm-teardown.sh` (companion safety and return), `bin/fm-pr-check.sh` (`--also`), `bin/fm-pr-merge.sh` (companion mode), `tests/fm-also-companion.test.sh` | those files, `tests/lib.sh` (`fm_fake_treehouse_pool` `get --lease`), `tests/fm-teardown.test.sh`, `tests/fm-pr-merge.test.sh`, `tests/fm-brief.test.sh`, `.agents/skills/ship-landing`, `docs/task-lifecycle.md`, `docs/scripts.md` | conflicted | 45dd50a5 |
