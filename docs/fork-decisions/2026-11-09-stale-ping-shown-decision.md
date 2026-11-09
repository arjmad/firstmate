2026-11-09: The firstmate operations audit of 2026-11-09 (fix 5) found that 26 of 39 helm turns for stale-liveness pings on workers waiting on the captain's open decision were no-ops, and Arjun's audit request covers its routine fixes.
Decision: a plain `stale:` ping goes to the supervision branch or host engine when its task's only reason to reach the helm is a decision already shown to the captain.
A decision is already shown when it was already open at the task's status-presentation cursor and no line since re-raised its key, or when a `captain-held` close transferred it to a verified captain hold.
A decision not yet presented, a missing or unmatched cursor, a second decision not yet shown, or an unread decision row for the task keeps the ping on main.
Worker status wakes, the decision signal itself, check wakes, heartbeats, and the away posture keep their routing.
The branch prompt treats such a ping as a liveness check and never answers or releases the decision.
Why: the decision itself still reaches the captain at once on its own signal, so the later liveness ping adds nothing to the helm unless the worker needs recovery.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A stale row is decision-owned only while its task's open needs-decision is not yet shown, read from the presentation cursor; a `captain-held` close counts as shown | `.pi/extensions/lib/fm-branch-dispatch.ts` (`staleDecisionUnshown`, `scopeForUnreadWake`, `branchOfferForWake` comments), `tests/fm-pi-branch-extension.test.sh` (`test_branch_dispatch_routes_stale_by_shown_decision`, captain-held and second-mate stale cases), `docs/pi-supervision-branch.md` (Decision-owned rows) | `.pi/extensions/lib/fm-branch-dispatch.ts`, `tests/fm-pi-branch-extension.test.sh`, `docs/pi-supervision-branch.md` | carried | c8d8fdad |
| The branch prompt reports a stale ping on a shown decision as routine liveness and never answers or releases it | `bin/fm-branch-prompt.sh`, `tests/fm-branch-supervision.test.sh` (`test_branch_prompt_is_byte_stable_and_above_cache_floor`) | `bin/fm-branch-prompt.sh`, `tests/fm-branch-supervision.test.sh` | carried | c8d8fdad |
