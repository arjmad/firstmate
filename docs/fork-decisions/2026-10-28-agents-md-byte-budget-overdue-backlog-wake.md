PR: #145

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Keep `AGENTS.md` under Codex's project-doc byte budget: conditional detail moves to its owning skills and docs, and a colocated test fails once the file nears the budget | `AGENTS.md`, `.agents/skills/firstmate-self-repo/SKILL.md` (the `--project` brief line), `.agents/skills/secondmate-provisioning/SKILL.md`, `.agents/skills/firstmate-coding-guidelines/SKILL.md`, `docs/configuration.md`, `docs/scripts.md`, `bin/fm-agents-md-budget.sh`, `tests/fm-agents-md-budget.test.sh`, `bin/fm-test-run.sh` | `AGENTS.md`, those three skills, `docs/configuration.md`, `docs/scripts.md`, `bin/fm-test-run.sh` | carried | 427056c4 |
| Wake firstmate once when a queued backlog item's date gate opened more than 12 hours ago with no blocker and no dispatch | `bin/fm-backlog-overdue.sh`, `bin/fm-watch.sh` (hourly tick), `docs/task-lifecycle.md` (the overdue wake), `docs/configuration.md` (its runtime markers), `docs/scripts.md`, `tests/fm-backlog-overdue.test.sh` | `bin/fm-watch.sh`, `docs/configuration.md`, `docs/scripts.md` | superseded by #279 | 427056c4 |
