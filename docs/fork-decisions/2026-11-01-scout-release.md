2026-11-01: Arjun answered the nine-day landing review board's scout-release card "adopt".
Decision: a scout ends once its report, and its board when it has one, exist; firstmate holds its open call bound to the board, tears the scout down without waiting for the answer, and the answer starts a fresh ship rather than a promotion.
Why: scouts spent 413 of their 487 hours waiting on the captain's answer, about two worker slots on average, and one waited 129 hours and another 69 hours for promotion.
Teardown's report, scratch-only, and unresolved-decision gates and its board handover to firstmate are unchanged and carry the release.
No upstream proposal: it composes the fork's scout board handover (2026-10-27) with upstream's completion gate.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Firstmate releases a scout at report time, holds its calls through the completion gate bound to its board, and dispatches a fresh ship on the answer | `.agents/skills/scout-completion/SKILL.md` | the scout outcome and promotion procedure | carried | 45dd50a5 |
| The scout brief puts a question its finished report leaves in the report and declares done instead of waiting, hands its board over at done, and names a fresh ship rather than promotion | `bin/fm-brief.sh` (scout rule 6, `LAVISH_LINE`, scout Definition of done) | scout brief text | carried | 45dd50a5 |
