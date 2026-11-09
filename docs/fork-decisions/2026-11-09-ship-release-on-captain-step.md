2026-11-09: Firstmate's operations audit 1109, run on Arjun's 2026-11-08 request to audit how firstmate runs and make it optimal, extended his adopted scout release (2026-11-01) to ships as a routine item.
Decision: once a ship's PR, and every companion PR, has merged and only a step Arjun must take himself remains, the ship reports `done: PR <url> merged; captain step: <action>` instead of waiting on it; firstmate holds the ship's own row for him with that exact action and tears the ship down, and his answer closes the row or, when work remains, releases it to a fresh short ship.
Why: ships spent 117 hours waiting on him, 44% of all ship wait time, and four of the five longest had already merged and waited only on a physical step, such as linking a bank account at the office or his next game launch.
Teardown's landed-work test is unchanged, so a ship with unmerged or unlanded work is never released by this rule, and a call that gates the work before its merge still waits on the live worker.
No upstream proposal: it composes the fork's scout release and `[on=captain]` status tag with upstream's ship landing.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Firstmate releases a merged ship whose only remaining step is the captain's own, holding that step on the ship's row and tearing the worker down | `.agents/skills/ship-landing/SKILL.md` | the ship landing and cleanup procedure | carried | 45dd50a5 |
| The ship brief tells a worker whose PR merged to report its captain step in `done:` rather than wait on it | `bin/fm-brief.sh` (`SHIP_READY_INSTRUCTIONS`, header), `tests/fm-brief.test.sh` (custom pause verb test), `tests/fm-dod-lib.test.sh` (`test_merged_pr_captain_step_done_is_accepted`) | ship brief text | carried | 45dd50a5 |
