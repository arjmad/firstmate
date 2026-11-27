2026-11-27: Arjun approved audit a4-15 at the third deep-audit walk: "Build it".
Decision: `bin/fm-pr-merge.sh` refuses a github.com/arjmad/sites PR whose body's Visual review section is not `none` unless `--captain-approval-file` is given, so a customer-visible React site no longer deploys on Vercel at merge without Arjun's recorded yes; that flag stays refused while away, so such a PR waits for him.
It reads `Visual review: none` as sites' `theme-go-live.py` does, so the merge and the theme go-live agree on which PR is customer-visible.
No upstream proposal: the captain-approval convention is this fork's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Refuse a customer-visible sites PR without the captain's approval | `bin/fm-pr-merge.sh` (header, `pr_body_visual_review_none`, `require_visual_review_approval`), `.agents/skills/ship-landing/SKILL.md`, `docs/task-lifecycle.md`, `tests/fm-pr-merge.test.sh` (`test_sites_visual_review_*`) | `bin/fm-pr-merge.sh`, `.agents/skills/ship-landing/SKILL.md`, `docs/task-lifecycle.md`, `tests/fm-pr-merge.test.sh` | carried | 58eee9b7 |
