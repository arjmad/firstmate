2026-11-26: Arjun approved the idea "The captain-answer record stores a machine Resolved at timestamp" ("Build (Recommended)").
It follows the 2026-11-25 later-rulings record ([`2026-11-25-later-rulings-at-landing.md`](2026-11-25-later-rulings-at-landing.md)), whose approval date came only from the first date in the captain's words.
Decision: every resolution block `bin/fm-captain-hold.sh` writes carries a `Resolved at:` UTC stamp of when it was recorded, and `bin/fm-later-rulings.sh` dates an approval from that stamp on an `answered` or `released` record, keeping the prose date for a record that lacks a well-formed stamp and for a `repaired` one, which is recorded after the fact.
This supersedes the 2026-11-25 record's sentence that the approval date is the first date of the decision text; the earliest record still wins.
The stamp's day is the earlier of its UTC day and the host's local day, so a ruling the captain dated later the same local evening still lists.
Known limit: the stamp dates when the answer was recorded, so an answer recorded well after he gave it dates the approval late and can list fewer rulings than the prose date would.
`defer` writes no resolution block and already stamps `Captain deferred:`, so it is unchanged.
No upstream proposal yet: the later-rulings listing it feeds is this fork's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Stamp each captain-hold resolution with a machine `Resolved at:` time and date later-rulings approvals from it | `bin/fm-captain-hold.sh` (`resolution_block`, header), `bin/fm-later-rulings.sh` (`approval_date_from_body`, header), `docs/captain-hold-lifecycle.md`, `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-later-rulings.test.sh`, `tests/fm-pr-merge.test.sh` (`test_later_rulings_are_listed_without_blocking_the_merge`) | `bin/fm-captain-hold.sh`, `docs/captain-hold-lifecycle.md`, `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-pr-merge.test.sh` | carried | 427056c4 |
