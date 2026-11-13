2026-11-13: Firstmate fixed a noticed row on its own, under Arjun's standing 2026-11-11 rule that the fleet fixes reversible noticed rows when they pay off: merge-gate `/code-review` findings did not always reach the PR thread.
The worker's note blamed a dropped `--comment`, but the reviewer's transcript showed the flag arrived and its prompt held the posting section.
The skill's posting step is optional by its own text ("fall back to `gh api` ... or print the findings instead"), and on firstmate PRs #243, #245 and #248 the reviewer printed 4, 3 and 4 findings and posted none, citing this repository's `AGENTS.md` upstream-comment rule or its own JSON output contract.
Decision: `bin/fm-code-review.sh review <pr-url> --model <model>` runs the headless review with no `--comment` and posts every finding of the JSON findings block the skill ends its reply with, inline on the PR's head, or as a general PR comment naming the file and line when GitHub refuses the inline one; the ship brief and the merge refusal name that command.
One poster, the script, so nothing posts twice and no reviewer judgment decides whether findings reach the forge.
`args` keeps printing the hand-run form with `--comment` for workers briefed before this change.
This replaces the `args` route that [the 2026-11-10 focus record](2026-11-10-code-review-focus.md) and [the 2026-11-11 model record](2026-11-11-code-review-model.md) name for the ship worker's step; the focus and the model pin are unchanged.
The record a merge checks is unchanged.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `review` runs the headless `/code-review` and posts its findings | `bin/fm-code-review.sh` (header, `code_review_post_findings`, `code_review_run`, `code_review_focus_line`, `review`), `tests/fm-code-review.test.sh`, `docs/scripts.md` | none (fork-only script) | carried | c8d8fdad |
| The ship worker's review step and the merge refusal name `review` | `bin/fm-dod-lib.sh` (`fm_dod_code_review_block`, header), `tests/fm-dod-lib.test.sh`, `bin/fm-pr-merge.sh` (header, unreviewed refusal message), `docs/task-lifecycle.md` (Code review before merge), `docs/configuration.md` (Code review model) | `bin/fm-dod-lib.sh`, `bin/fm-pr-merge.sh`, `docs/task-lifecycle.md`, `docs/configuration.md` | carried | c8d8fdad |
