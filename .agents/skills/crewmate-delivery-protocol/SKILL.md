---
name: crewmate-delivery-protocol
description: >-
  Read by path when a ship brief's Definition of done points here: before a worker on a GitHub PR runs its code review step, and before it waits for that PR's checks.
user-invocable: false
metadata:
  internal: true
---

# Crewmate delivery protocol

Your brief's Definition of done points here and keeps only the lines you must see first; this file holds every delivery step in full, with each stop and escalation.
Where your brief and this file differ, your brief wins.
`<review script>` below is the `fm-code-review.sh` path your brief names, and `<model>` is the pinned review model it names.
Where a step says to push, a direct-PR worker pushes from its copy, and a no-mistakes worker commits and runs /no-mistakes again so the pipeline pushes it.

## Code review

This step applies to a code-changing GitHub PR, before the done report; a PR on any other forge skips it.

1. Run `<review script> status <pr-url>`.
   `exempt` or `reviewed` needs nothing more, except the gate statement in step 6 when `status` says the PR edits its own gate files, so a tinker-tier or docs-only PR runs neither review below.
2. On `unreviewed`, first run the `tstack-sol-loop` skill on your branch against the PR's base once the local checks the repository's own guidance names pass on it.
   GPT Sol on the Codex subscription reviews the change for at most 3 rounds, never the skill's extended 5, and the skill's own rules decide when the loop stops.
   Settle each Sol finding as that skill says: fix the real ones with the smallest change, and decline nits and out-of-scope findings in one line in its ledger.
   The skill pushes nothing during the loop, so push its fixes once the loop ends, and add the PR-body line the skill asks for.
3. When the skill hands an open finding to its user - one disputed twice, or a blocker or should still open when the rounds run out - that user is firstmate: append `needs-decision [at=<epoch>]: {the open Sol findings}` and stop.
   This step is the ask that skill waits for.
   Where the skill would report a blocker because nothing here can reach Sol - the skill is not installed, Codex is not signed in, or no route runs Sol - skip the loop instead, never substitute another model, append `working [at=<epoch>]: Sol skipped: {reason}` so firstmate sees it, and keep the reason for the record note.
4. Then run Claude Code's built-in `/code-review` once on the pinned model with the shell command `<review script> review <pr-url> --model <model>`.
   It runs the review headless with firstmate's merge-gate focus in a throwaway checkout, never your own, and then posts each finding to the PR itself; a refused URL runs no review.
   Do not invoke the skill in your own session instead: an in-session skill runs on the session's model, and a worker cannot switch its own session's model, so only the headless command pins it.
   A medium review takes longer than a shell tool's default time limit, so run that command in the background or with your harness's longest command timeout, and wait for it to exit before you go on.
   If the command cannot run here, or `review` exits non-zero, append `blocked:` naming its error instead of done.
5. Then push a fix for every finding you agree is real, and reply in the PR thread of every finding you do not.
   After your last push, run `<review script> record <pr-url> --note 'Sol: <N> rounds, <model>, <verdict>'`, or `--note 'Sol: skipped, <reason>'` when the loop could not run, with no apostrophe in the note, and confirm it prints `reviewed`.
6. When `status` or `record` says the PR edits its own gate files, also pass `--gate '<what the change loosens or tightens against the base branch gate, or nothing loosened>'` to that `record`, with no apostrophe in it.
   Run it even on `reviewed` until `status` no longer says the PR edits its own gate files; an `exempt` PR needs no statement.
7. Pushes that fix or answer this review's findings are covered by the one `record` you run after your last push.
   Only a push after `record` that changes the diff needs a new review, and a rebase that leaves the diff alone needs none.
8. For a small follow-up pushed after `record`, run `<review script> record <pr-url> --carry` instead of a new review.
   The script decides what a carry covers, and when it refuses, its message says whether to run the carry again or `/code-review` again.
9. Before such a new `/code-review`, run `tstack-sol-loop` again as a fresh loop of one round on the change since the record, outside the first loop's 3, settle and escalate its findings as in steps 2 and 3, and name that round in the new `record`'s note.
10. Count this PR's full records, the `fm-code-review v1` comments you posted without a `fm-code-review-carry` or `fm-code-review-gate` line, rather than relying on memory.
    With three already posted, a change that would need another `/code-review` pass does not get one: append `needs-decision [at=<epoch>]: {why the PR keeps needing review}` and stop instead of looping.

## Checks

This step applies to a direct-PR worker on a GitHub PR, after the code review and before the done report.

1. Wait for the PR's checks at your pushed HEAD: run `gh-axi pr checks <number> --watch --fail-fast`, and while it waits append `gate-wait [at=<epoch>]: checks on PR {url}` instead of reporting done.
   A PR held as a draft until reviewed is marked ready (`gh-axi pr ready <number>`) before this wait, as your brief says; on such a repository a failing draft-only check, such as firstmate's `Ready for review`, is that hold, not a defect to fix.
2. A failing check is yours to fix: append `working [at=<epoch>]: fixing {check}`, push the fix, and wait again.
3. A required check that has never reported is missing from that list rather than pending, so also read `gh-axi pr view <number>`: a `merge_state` of blocked while every listed check is green means a required check has not posted, so watch again until it posts and passes.
4. When that check's Actions run, found with `gh-axi run list --branch <branch>`, stays `queued` with no jobs in `gh-axi run view <id>` for over 10 minutes, as after a GitHub Actions outage, GitHub refuses to cancel or rerun it.
   Run `gh-axi pr close <number>` then `gh-axi pr reopen <number>`, which starts a fresh `pull_request` run at the same head, and wait again.
   That close keeps the branch, so never close this way with `bin/fm-pr-close.sh` or `--delete-branch`.
5. A repository with no checks at all reports none, which leaves nothing to wait for.
6. A required `fleet-gate` or `gate` status posts only from a full `./check.sh` run on a clean tree whose HEAD is already pushed.
   Run it after your last push (on a PR held as a draft until reviewed, whose CI runs the suite when it is marked ready, the local run is optional and belongs before you mark it ready), a rebase or force-push included because the new head has no status yet, never as a single-suite run, and with no untracked files left in the tree.
