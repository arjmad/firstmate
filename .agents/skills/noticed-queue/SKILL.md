---
name: noticed-queue
description: Load when teardown prints a `noticed-queue:` line, an inbox note is a fleet-handoff notice, the wake drain prints NOTICED, you notice a problem outside the task at hand, or the Monday `[open-items]` note arrives.
user-invocable: false
metadata:
  internal: true
---

# Noticed queue and idea capture

Arjun's design of 2026-10-27 (brain facts 8944, 8990, 9027, 9064 on `systems/platform/firstmate`): agents stay on task, but what they notice is kept, and good ideas reach him without noise.
A **noticed** item is something broken outside the task that noticed it.
An **idea** is something that could make the ecosystem better.
Both are captain holds, so nothing here ever dispatches work; a pick or fix starts only from his answer.
`bin/fm-noticed.sh --help` owns the mechanics; this file owns the judgment.

## Filing

Firstmate is the only writer.
Items arrive four ways: a teardown's `noticed-queue:` lines, a fleet-handoff notice in the inbox (`[<agent>] notice: ...`), a scout report, and what firstmate itself notices.
Each task yields at most one noticed and one idea; `none` and an empty section are normal.

1. Run `bin/fm-noticed.sh list` and look for an open item about the same broken thing or the same idea.
   Reuse its slug when one matches, so `file` attaches the new evidence instead of filing a duplicate.
2. File with `bin/fm-noticed.sh file noticed|idea <slug> --title <one line> --why <why it may matter> --from <task or agent> [--repo <repo>] [--evidence <pointer>]`.
   Capture the observation and why it may matter; leave value unknown until ranking.
3. Acknowledge a fleet-handoff notice with `bin/fm-inbox.sh drain --ack <id>`, and reply with the item id through `bin/fm-inbox.sh reply <id>`.

Done when every collected line is filed, matched, or judged not an item, with each judgment in one line of your next captain reply.
Sapna's agents never file here: a Nova notice is refused, and a secondmate home files into its own backlog.
Mining transcripts for items is out of scope.

## Showing each item once

The wake drain's NOTICED section lists noticed items and this week's top ideas no captain reply has mentioned.
Mention each in one plain line in your next captain reply, then run `bin/fm-noticed.sh shown <id>...`.
A filed idea is not mentioned on its own; it waits for the Monday ranking.

## Monday: sweep and top 3

The jobs launcher's Monday `[open-items]` note dispatches the open-items sweep scout.
Add two duties to that scout's brief:

- **Noticed re-check.** Re-check every open noticed item (`bin/fm-noticed.sh list noticed`) against live state.
  Firstmate closes a fixed one with `bin/fm-noticed.sh close <id> --evidence <what fixed it>`, and tells Arjun in one line of the next reply about any item still broken 7 days or more after its `created` date, with the recommended fix.
- **Top 3.** Rank the open ideas never in a top 3 with Atlas's ranking rule (the atlas skill's step 2: Ecomills and Kempf profit first, then Arjun's time), estimating each as $/week or hours/week, and return the best three with their estimates.
  Firstmate records them with `bin/fm-noticed.sh top3 <id>...`, and the drain then shows them once.

The Atlas board itself still builds only when he asks.

## Weekly exploration scout

The same Monday note dispatches one read-only exploration scout.
Its area rotates by ISO week number (`date -u +%V`) modulo 3:

| Week mod 3 | Area |
| --- | --- |
| 0 | Amazon and Walmart program, fee, policy and seller-API changes |
| 1 | Upstream features of tools the fleet uses (Claude Code, Codex, Hermes, GBrain, Shopify, Nix tools), favouring what replaces custom code |
| 2 | Business-data blind spots: slow movers, margin leaks, returns, ad spend not paying back |

Competitors are not on the rotation.
Scaffold it with `bin/fm-brief.sh explore-<area>-<mmdd> <repo> --scout` and dispatch it like any scout on the worker account, which is the Ecomills Claude account; its budget is that one scout's share of the account's week.
Skip the week rather than add a second scout or a paid tier, and say so once.
The brief is read-only everywhere: no spend, no store or listing change, nothing customer-visible.
Its findings reach Arjun only through idea capture and the Monday top 3, never as a message of their own.

## Review

Four weeks after launch, review from the captured examples, the picks, the value shown, and any distraction or triage cost seen; add no instrumentation, and remove nothing automatically.
