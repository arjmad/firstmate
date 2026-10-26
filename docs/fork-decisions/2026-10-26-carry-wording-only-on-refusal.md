| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The worker's carry step ends "only a refusal sends you back to `/code-review`" instead of "and then you run `/code-review` again", which read as a new review after every carry; wording only, from the 2026-10-26 code-review pass | `bin/fm-dod-lib.sh` (the carry line of `fm_dod_code_review_block`) | `bin/fm-dod-lib.sh` (`fm_dod_code_review_block`) | carried | 45dd50a5 |
