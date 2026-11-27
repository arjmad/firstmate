2026-11-27: Arjun approved a1-60 ("Build both") in the 2026-11-26 deep audit's helm walk.
`bin/fm-audit-landed-by.py` now derives `landed_by` from merged PRs that name the id, found with `gh search prs --merged` across the fleet's owners, instead of from URLs in a wrap-up ledger's evidence cells.
The ledger cells had named PRs that never merged and missed PRs that had, so the next audit's recheck started from a wrong record.
It stamps only a merged PR that names the id and writes a `landed` status when it stamps, and the next audit's prior-status table is built from the same search.
Firstmate ruled the same day that an id whose status is `open-helm` or `open-captain` gets the PR URLs but keeps its status, because on the 2026-11-24 data most such stamps were half-landings whose live step was still open; the helm sets `landed` when that step closes.
This supersedes the ledger input of the [2026-11-25 record](2026-11-25-audit-landed-by.md).

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The landed-by tool reads merged PRs that name each id instead of ledger cells, holds an open-helm or open-captain status, keeps a merged hand-entered URL, drops an unmerged one, never un-stamps, and writes the prior-status table with `--table` | `bin/fm-audit-landed-by.py`, `tests/fm-audit-landed-by.test.sh`, `docs/scripts.md` | `docs/scripts.md` | carried | 427056c4 |
