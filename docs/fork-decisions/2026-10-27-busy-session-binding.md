PR: #129

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A Claude worker's busy incarnation binds to the first hook session that posts (`--session-from-payload`, `state/<id>.busy-session`), so a nested `claude` run started in the worktree cannot write idle into the worker's busy record or touch its turn-ended marker | `bin/fm-busy-event.sh` (`apply --session-from-payload`), `bin/fm-busy-lib.sh`, `bin/fm-spawn.sh` (Claude worker hooks), `bin/fm-turnend-guard.sh`, `docs/turnend-guard.md`, `.agents/skills/harness-adapters/references/harness/claude.md`, `.agents/skills/operational-home-layout/SKILL.md`, `tests/fm-busy-adapter-wiring.test.sh`, `tests/fm-busy-state.test.sh` | the same files | carried | 9ac0288e |
