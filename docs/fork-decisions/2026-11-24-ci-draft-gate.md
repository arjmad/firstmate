2026-11-24: Arjun approved audit item a1-32 in the 2026-11-19 deep audit walk, because 39 of 77 pull request runs were cancelled by a newer push and those cancelled runs spent about 4,460 job-minutes, as much as the 24 successful runs.
Decision: a draft pull request runs only the quick checks and a failing `Full suite` verdict that says to mark it ready, marking it ready runs the full suite once on its head, and a draft's runs keep a concurrency group of their own so a late draft run cannot cancel that one full run; firstmate's own pull requests stay drafts until their reviews are done.
Why: review-fix pushes are what supersede most runs, and the fleet repository's gate cut its cancelled runs the same way (https://github.com/arjmad/fleet/pull/1177); the failing verdict keeps a draft head from reading as fully tested, since this fork has no required checks and `bin/fm-pr-merge.sh` reads only the checks that reported.
Upstream at 427056c4 has no draft condition, so this is a fork patch.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A draft pull request runs only the quick checks and fails `Full suite` until it is marked ready, `ready_for_review` starts the full suite, and draft runs keep their own concurrency group | `.github/workflows/ci.yml` (`ready_for_review` trigger, concurrency group, the draft condition on every full-suite job, the `Full suite` draft verdict), `tests/fm-ci-workflow.test.sh` | `.github/workflows/ci.yml`, `tests/fm-ci-workflow.test.sh` | carried | 427056c4 |
| The contributor guide says to keep a pull request a draft until its reviews are done and what a draft runs | `CONTRIBUTING.md` CI paragraph | `CONTRIBUTING.md` | carried | 427056c4 |
