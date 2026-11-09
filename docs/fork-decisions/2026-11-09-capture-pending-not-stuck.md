2026-11-09: Arjun asked on 2026-11-08 to audit how firstmate runs, and the firstmate operations audit (ops audit 1109, fix 2b) found fleet-sync sent 24 STUCK wakes about Nova's live copy in a week, five of them after #192, while the newest said its capture had already run.
Decision: a live checkout behind origin, held only by edits under its `capture=` dir whose capture succeeded and whose log names a pull request `gh pr view` reads as open, reports `capture-pending <PR url>` instead of STUCK; with no open capture PR, or ahead of origin, it stays STUCK.
Why: those edits wait only for the capture PR to land, whose settle fast-forwards the checkout, and the capture job's own note already puts that PR in front of firstmate, so the STUCK wake was a second alarm for the same pending landing.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A capture-held checkout behind origin whose capture log names an open PR reads `capture-pending <PR url>`, which the scheduled sync never queues as a wake | `bin/fm-fleet-sync.sh` (`capture_open_pr`, `report_capture_held`, header), `tests/fm-fleet-sync.test.sh` (`test_open_capture_pr_pends_instead_of_stuck`), `docs/configuration.md` live-checkouts `capture=` paragraph | `bin/fm-fleet-sync.sh` (header), `docs/configuration.md` | carried | c8d8fdad |
