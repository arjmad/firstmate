| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The `AGENTS.md` byte-budget check sums the root and every nested `AGENTS.md` git tracks, because Codex shares one `project_doc_max_bytes` budget across the chain, and its overrun points at "Maintaining this file" and says to prune, not raise the limit | `bin/fm-agents-md-budget.sh`, `tests/fm-agents-md-budget.test.sh`, `docs/scripts.md`, `bin/fm-test-run.sh` (the `*/AGENTS.md` selection) | `docs/scripts.md`, `bin/fm-test-run.sh` | carried | 427056c4 |
