2026-11-25: Arjun approved audit a4-09 at the deep-audit walk: "add the guard (merge helper writes 'Approved: Arjun <date>: <words>' on the PR; theme-go-live.py refuses a customer-visible PR without it)".
Decision: an attended `bin/fm-pr-merge.sh --captain-approval-file <path>` posts one GitHub PR comment whose first line is `Approved: Arjun <YYYY-MM-DD>: <his words>` and whose second line names the verified head, just before the forge merge; a failed post refuses the merge, and the flag is refused while away.
The reader contract is `^Approved: Arjun [0-9]{4}-[0-9]{2}-[0-9]{2}: .+`; the sites go-live reader lands after this patch.
No upstream proposal: the captain-approval convention is this fork's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Post the captain's approval on the PR before a customer-visible merge | `bin/fm-pr-merge.sh` (header, argument parse, `require_current_away_authority`, `post_captain_approval`), `.agents/skills/ship-landing/SKILL.md`, `docs/task-lifecycle.md`, `tests/fm-pr-merge.test.sh` (`test_captain_approval_file_*`) | `bin/fm-pr-merge.sh`, `.agents/skills/ship-landing/SKILL.md`, `docs/task-lifecycle.md`, `tests/fm-pr-merge.test.sh` | carried | 9ac0288e |
