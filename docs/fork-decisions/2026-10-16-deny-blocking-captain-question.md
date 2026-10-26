PR: #83

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Deny a blocking captain question (`AskUserQuestion`) in a primary home with fleet work under way, so supervision keeps re-arming at turn end | `bin/fm-question-pretool-check.sh`, `tests/fm-question-pretool-check.test.sh`, `tests/fm-question-pretool-check-live-e2e.test.sh` | `.claude/settings.json`, `AGENTS.md` section 9, `docs/supervision-protocols/claude.md`, `bin/fm-test-run.sh`, `docs/scripts.md`, `docs/verification/runtime-backends.md`, `tests/fm-turnend-guard.test.sh` | carried | 45dd50a5 |
