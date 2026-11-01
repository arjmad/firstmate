---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
Relay findings that carry a captain call together with that call, at once or at the next decision sitting as `captain-hold-lifecycle` "Decision sittings" decides; findings with no call are relayed at once.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.

Release a scout at report time (fork patch, `docs/fork-decisions.md` 2026-11-01): once its report exists, and its board when it has one, the scout's work is done even when the captain still owes it an answer.
Its brief tells it to put such a question in the report and declare done rather than wait; a scout already stopped on a `needs-decision` line that the report can stand without is the same case.
In the turn that reads the report, make sure every open call is a captain-held task with `--origin <scout-id>`, held by the scout or by you, then run `bin/fm-captain-hold.sh complete` with that inventory, which also transfers any keyed status decision the scout left open, and tear the scout down without waiting for the answer.
Teardown hands each board to firstmate and records the board's link on every still-open call of the inventory (`docs/configuration.md` "Hand a finished scout's board to firstmate"), so the call stays bound to the board and his board answer resolves it.
Teardown's report, scratch-only, landed-work, and unresolved-decision gates are unchanged: fix what a refusal names, such as an unread board round, and never force past it to release a scout.
Hold each call on the work item its answer would start when one exists, so `answer --release` returns that row to the queue.
When his answer authorizes implementation, dispatch a fresh ship whose brief carries his words and points at the scout's report and board, rather than keeping or promoting the torn-down scout.

A scout stays alive only while the captain is iterating its visual artifact with it, a round of his feedback in progress that the scout must revise; follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
Once a round leaves a call rather than a revision, release it as above.
When implementation is authorized while a scout is still live, `bin/fm-promote.sh` may promote it in place rather than creating a duplicate task, but a scout is never kept parked to wait for promotion.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
