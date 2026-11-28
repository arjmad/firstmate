2026-11-28: Arjun ruled at the helm ("Build it") that audit finding ids are numbered uniquely across audits, so the landed-by tool's `--also` becomes a safety net and not a required input.
Every prefix but a7 already continued its numbers from audit to audit, while the a7 run started again at a7-01 in the 2026-11-24 and 2026-11-26 audits after the 2026-11-19 audit, so PRs for a later audit's a7-05 and a7-07 named an earlier audit's ids too.
Decision: `bin/fm-audit-ids.py next` prints each prefix's first free number past every earlier audit's records, for the auditors' briefs, and `check` refuses an audit record whose ids an earlier audit holds, because the auditors that mint ids are agents and a convention alone already failed once.
Ids already filed keep their numbers; `--also` stays for those three audits, which share a7 ids.
This narrows the `--also` part of the [2026-11-27 record](2026-11-27-audit-landed-by-merged-prs.md).

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A tool prints each audit-id prefix's next free number across earlier audits and refuses an audit record that reuses one; landed-by's `--also` help reads as a safety net | `bin/fm-audit-ids.py` (new), `tests/fm-audit-ids.test.sh` (new), `bin/fm-audit-landed-by.py` (`--also` help), `tests/fm-audit-landed-by.test.sh` (`test_unique_ids_need_no_also`), `bin/fm-test-run.sh` (serial weight hint), `docs/scripts.md` | `bin/fm-test-run.sh`, `docs/scripts.md` | conflicted | 9ac0288e |
