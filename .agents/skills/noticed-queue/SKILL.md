---
name: noticed-queue
description: Load when teardown prints a `noticed-queue:` line, an inbox note is a fleet-handoff notice, the wake drain prints NOTICED, you notice a problem outside the task at hand, the Monday `[open-items]` note arrives, or you write Atlas's ideas.
user-invocable: false
metadata:
  internal: true
---

# Noticed queue and idea capture

Arjun's design of 2026-10-27 (brain facts 8944, 8990, 9027, 9064 on `systems/platform/firstmate`), funnelled on 2026-11-08: agents stay on task, what they notice is kept, and only what needs him reaches him.
A **noticed** item is something broken outside the task that noticed it.
An **idea** is something that could make the ecosystem better.
A noticed item that needs his decision or review, and every idea, is a captain hold, so filing never dispatches work and a pick starts only from his answer; a routine noticed item is the fleet's own work from the start (see Acting first).
`bin/fm-noticed.sh --help` owns the mechanics; this file owns the judgment.

One funnel: workers, Cade, Codex and the second mate hand what they notice to firstmate, never to Arjun directly; an agent already in a live chat with him may add one line at the end of that reply.

## Filing

Firstmate is the only writer.
Items arrive four ways: a teardown's `noticed-queue:` lines, a fleet-handoff notice in the inbox (`[<agent>] notice: ...`), a scout report, and what firstmate itself notices.
Each task yields at most one noticed and one idea; `none` and an empty section are normal.

1. Run `bin/fm-noticed.sh list` and look for an open item about the same broken thing or the same idea.
   Reuse its slug when one matches, so `file` attaches the new evidence instead of filing a duplicate.
2. File with `bin/fm-noticed.sh file noticed|idea <slug> --title <one line> --why <why it may matter> --from <task or agent> [--repo <repo>] [--evidence <pointer>] [--now] [--routine]`, adding `--routine` to a noticed item Acting first settles on its own.
   Capture the observation and why it may matter; leave value unknown until the triage.
   Add `--now` only to a noticed item that is urgent or doing harm now: money, customers, account health or security; filing an open item's slug again with `--now` makes it urgent.
3. Acknowledge a fleet-handoff notice with `bin/fm-inbox.sh drain --ack <id>`, and reply with the item id through `bin/fm-inbox.sh reply <id>`.

Done when every collected line is filed, matched, or judged not an item.
Sapna's agents never file here: a Nova notice is refused, and a secondmate home files into its own backlog.
Mining transcripts for items is out of scope.

## Acting first

Firstmate settles what it can before anything reaches Arjun (Arjun, 2026-11-11, rule 1 of the calls-grouping board).
A noticed item is held for him only when it needs his decision or review: an ask-first item, a rule or ruling, retiring a part, an addition of new machinery, or anything of Sapna's.

- **Routine.** Every other noticed item is the fleet's to fix or drop, provided the change can be undone and stays inside firstmate's authority (a broken test, a stale doc, a small bug, a finding that turns out moot).
  File it with `--routine`, so it is fleet work rather than a call, and either dispatch that row as its fix or drop it.
  Once the fix lands, close it with `bin/fm-noticed.sh close <id> --evidence <what changed> --fixed --pr <PR URL>` (the PR is required); to drop it, close it with `--dropped` and the reason.
  Both record it for the Monday "Handled for you" list (Arjun, 2026-11-08: "i want to be made aware of noticed changes you make").
- **Duplicate.** A repeat sighting is matched to its open item at filing and never becomes a second one.
- **Below the bar.** An idea that fails the idea bar stays filed and unshown.

## What reaches him

Only two things reach Arjun from this queue.

- **NOW.** A noticed item filed with `--now`, urgent or doing harm (money, customers, account health, security), is the only thing the wake drain's NOTICED section prints.
  Tell him this turn, leading the turn's final captain-facing message with it rather than burying it in other news, then run `bin/fm-noticed.sh shown <id>...`.
- **WEEKLY.** Everything else waits for the Monday triage below, which lists what firstmate fixed or dropped on its own and brings only the few items that need his call.

Do not mention a filed item in your next reply, unless it is a NOW item or bears on the topic at hand.

## Monday: sweep and triage

The jobs launcher's Monday `[open-items]` note dispatches the open-items sweep scout.
Add two duties to that scout's brief:

- **Noticed re-check.** Re-check every open noticed item (`bin/fm-noticed.sh list noticed`) against live state.
  Firstmate closes one fixed elsewhere with `bin/fm-noticed.sh close <id> --evidence <what fixed it>`, fixes a routine one under Acting first, and carries to the triage any item still broken 7 days or more after its `created` date that needs his call, with the recommended fix.
- **Ideas.** Check every open idea (`bin/fm-noticed.sh list idea`) filed in the 7 days before the sweep against the idea bar below, and return each one that passes as one line.

The weekly `triage-weekly` backlog row is where the result reaches him.
Open it with a "Handled for you" list: one line per `fixed` or `dropped` row of `bin/fm-noticed.sh unseen`, naming the item, what changed or why it was dropped, and the PR URL of a fix.
Then bring only the items from `unseen` and the sweep that need his call, each with a recommendation and a one-tap answer and each passing idea in one line, and park everything else.
Then add a "Waiting 2+ weeks" section (Arjun, 2026-11-11, rule 3): one line per call `bin/fm-noticed.sh waiting` prints, a call held 14 days with no date, each with Keep, Drop or a date.
No call is re-asked or closed by itself: Keep leaves it in its group, Drop closes it through `bin/fm-captain-hold.sh answer`, and a date defers it through `defer`, each only on his answer.
Then mark every unseen item the triage covered, brought or parked, with `bin/fm-noticed.sh shown <id>...`, and every waiting call it listed with `bin/fm-noticed.sh waiting --shown <id>...`, so each shows there once.

The Atlas board itself still builds only when he asks.

## The idea bar

An idea reaches Arjun, as an Atlas card or in the Monday triage, only when it passes all six tests below; when you write Atlas's ideas, apply them before you rank, and carry only those that pass, up to seven.
They come from his verdicts: he dropped all seven Atlas ideas of 2026-10-26 on quality ("Didn't like the ideas [it] came up with", 2026-10-28), and on the 2026-10-30 ecosystem board he kept 22 of the 39 ideas built on tools the fleet already runs and 1 of the 10 that brought a new platform.

1. **One concrete friction, seen.** Name one thing that went wrong or cost money or time, with a dated instance, and the smallest change that removes it.
   A broad new system, loop, standing rule or guide with no one failure behind it is not an idea: "a weekly profit decision loop" and "a taste guide per area" were dropped, while "one alert per Nova skill capture, not seven" and "instant 'got it' for every scan and print" were kept.
2. **Not already there.** Search the backlog, open captain holds, the noticed list, the skills store and the business stack's commands first.
   An idea a filed task or an existing skill already covers is evidence for that task, not a new idea: the 2026-10-26 disk-retention idea was the filed `task-media-retention`, and the FBA stock guard repeated what `inventory-worksheet` plans.
3. **No standing ruling against it.** Read the rulings in `data/captain.md` and the latest ecosystem review; an idea that reopens one needs new evidence that answers the reason he gave, and leads with it.
   The capped ad-budget rule ran into his no-standing-autonomy line for ad spend, and on the 2026-10-30 board the verdicts he skipped with a note mostly kept a setup he had already ruled on.
4. **Not his goal read back to him.** His standing goals in `data/captain.md` are the yardstick ideas are ranked by, not ideas themselves; "one daily ask list" restated a goal he had already set.
5. **His units, honestly counted.** The estimate is Ecomills or Kempf contribution profit per week, or his own hours per week, with the arithmetic in the evidence.
   Sales moved, agent hours and queue time are not his units: "$4,292/week moved", "~$1,900/week sales" and "~61 h/week of agent queue time" were all dropped.
6. **Built on what the fleet runs.** Prefer an upstream feature or a tool already in use; a new platform, device or vendor needs a payoff that clears its cost and upkeep.

An idea that fails a test stays filed and unshown; its next sighting may bring the evidence that passes it.

## Weekly exploration scout

The same Monday note dispatches one read-only exploration scout.
Its area rotates by ISO week number (`date -u +%V`) modulo 4:

| Week mod 4 | Area |
| --- | --- |
| 0 | Amazon and Walmart program, fee, policy and seller-API changes |
| 1 | Upstream features of tools the fleet uses (Claude Code, Codex, Hermes, GBrain, Shopify, Nix tools), favouring what replaces custom code |
| 2 | Business-data blind spots: slow movers, margin leaks, returns, ad spend not paying back |
| 3 | Code audit, one repository per turn |

Competitors are not on the rotation.
The code audit loads the `improve` skill from the skills store (`skills/improve`) and runs it at the `quick` level on one repository; its report carries the findings table and the rejected claims, it sends no notice, and firstmate files the findings as one batch.
Its repository is the first registered project in `data/projects.md` order with no earlier audit, else the one audited longest ago; an audit is a `data/explore-audit-*/report.md`, which names its repository and commit, plus `business` at `05a4200` on 2026-11-09, audited before the rotation.
Scaffold it with `bin/fm-brief.sh explore-<area>-<mmdd> <repo> --scout` and dispatch it like any scout on the worker account, which is the Ecomills Claude account; its budget is that one scout's share of the account's week.
Skip the week rather than add a second scout or a paid tier, and say so once.
The brief is read-only everywhere: no spend, no store or listing change, nothing customer-visible.
Its findings reach Arjun only through idea capture and the Monday triage, never as a message of their own.
Put the idea bar in its brief, so its ideas arrive already shaped to pass it.

## Review

Four weeks after launch, review from the captured examples, the picks, the value shown, and any distraction or triage cost seen; add no instrumentation, and remove nothing automatically.
