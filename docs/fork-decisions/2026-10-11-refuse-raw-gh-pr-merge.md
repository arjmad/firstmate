PR: #77

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Refuse a raw `gh pr merge`, `gh-axi pr merge`, or `gh api` merge call in a primary home, naming `fm-pr-merge.sh` | `bin/fm-merge-pretool-check.sh`, `bin/fm-merge-command-policy.mjs`, `.grok/hooks/fm-primary-merge-check.json`, `.opencode/plugins/fm-primary-merge-check.js`, `docs/merge-guard.md` | `.claude/settings.json`, `.codex/hooks.json`, `.cursor/hooks.json`, `.pi/extensions/fm-primary-turnend-guard.ts`, `.omp/extensions/fm-primary-turnend-guard.ts`, `bin/fm-test-run.sh`, `docs/scripts.md`, `docs/turnend-guard.md`, `docs/arm-pretool-check.md` | carried | 45dd50a5 |
