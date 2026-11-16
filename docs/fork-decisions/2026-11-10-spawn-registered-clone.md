PR: #226

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A fresh ship or scout, and each `--also` companion, takes a worktree only from a clone directly under the resolved `projects/` dir whose git common dir is its own `.git`, so a live checkout never adds slots to Treehouse's shared pool; relaunches and secondmates are unchanged | `bin/fm-spawn.sh` (`require_registered_clone`), `tests/fm-spawn-registered-clone.test.sh` (new), and the suites that now build their project under `projects/` | `bin/fm-spawn.sh`, the spawning suites under `tests/` | carried | 427056c4 |
