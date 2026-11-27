2026-11-25: Arjun released the idea from the 2026-11-24 audit wrap-up that an audit's decisions.json carries a landed_by PR URL list per id, written from the wrap-up ledger, so the next audit's recheck step starts from one file instead of every batch report.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A tool writes each landed audit id's PR URLs from a wrap-up ledger.md into decisions.json as landed_by, in place and idempotent, refusing an unknown id, a tableless ledger or a layout it cannot keep | `bin/fm-audit-landed-by.py` (new), `tests/fm-audit-landed-by.test.sh` (new), `bin/fm-test-run.sh` (serial weight hint), `docs/scripts.md` | `bin/fm-test-run.sh`, `docs/scripts.md` | superseded by #320 | 427056c4 |
