---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, before task cleanup, and on a `check: firstmate self-update due:` wake or a `self-update-due:` teardown line.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, or `done [at=<epoch>]: PR <url> checks green` on GitHub once every required check passed, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
A task spawned with `--also <repo>` reports each companion PR as `working: companion <repo> PR <url>`: record it with `bin/fm-pr-check.sh <id> <url> --also <repo>` and merge it with `bin/fm-pr-merge.sh` under the same authority, before or with the task's own PR; teardown refuses while any companion work is unlanded.
A worker whose task continues after its PR merges reports `ready [at=<epoch>]: PR <url>` instead (fork patch, `docs/fork-decisions.md` 2026-10-14): land it exactly like a done PR under the same merge authority, never as a decision, then leave the worker running and expect a later `done:`.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll, which also wakes the supervisor if the ready PR/MR later degrades (failing check, failed head pipeline, merge-train drop) so the worker can be steered to fix it.
With `config/pr-register-scan` present, the watcher can record ready task PRs during its check sweep, including replacing a named PR; see [`docs/configuration.md`](../../../docs/configuration.md#pr-registration-scan-configpr-register-scan) for the full rule. Handle a `check: pr-register:` notification as you would the same result from a manual run.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
Of those readers only `bin/fm-pr-check.sh` fetches the copy's remotes before it decides, and a no-mistakes pipeline pushes from its own clone, so a no-mistakes ready signal can read blocked until that registration has run: register it before steering.
A refusal that says it could not refresh a remote decided on the last-known refs, so retry it once that remote is reachable.
Otherwise that blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
When `bin/fm-pr-merge.sh` refuses a code-changing PR as unreviewed, follow `docs/task-lifecycle.md` "Code review before merge" rather than waiving it.
When it refuses a PR whose merge would undo landed work, steer its worker to rebuild the branch on the base with only its own change; an `actionable:` line after a landed merge naming undone commits needs a restoring follow-up PR.
When it refuses a one-way door and holds the task, bring the captain that merge call with the PR's full URL and blast radius; after his explicit word, record it with `answer --release` and re-run with `--one-way-approved` (`docs/task-lifecycle.md` "Selected delivery path and merge authority").
Act on a `STUCK:` line in `bin/fm-pr-merge.sh`'s output or a `check: fleet-sync:` wake; a `skipped: busy:` one needs nothing, because the scheduled sync retries it.
A merged firstmate PR goes live only through /updatefirstmate (fork patch): on a `self-update-due:` teardown line or a `check: firstmate self-update due:` wake, run it if `bin/fm-update.sh --due` still prints `due`; a `firstmate: skipped:` result is a blocker for the captain, not a step to repeat on the next wake or teardown line. A `held` result past a day names a task: check it with `bin/fm-crew-state.sh` and load `stuck-crewmate-recovery` when its record is stale.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

The watcher owns teardown of a merged lane whose merge poll is armed, including a PR merged through `bin/fm-pr-merge.sh`, when the lane is parked or its home has `config/auto-land` ([`docs/configuration.md`](../../../docs/configuration.md#park-on-review)), except a lane that reported `ready:`, which is never parked and which the watcher leaves running at its merge (fork patch). Otherwise, firstmate tears it down after landing is confirmed, and a `ready:` lane only after its later `done:`.
A lane parked on review (`bin/fm-park.sh`) has no agent and relaunches itself on review activity; `bin/fm-park.sh park <id>` parks one clean lane on request and `bin/fm-park.sh resume <id> --trigger <text>` relaunches one by hand.

Tear down any other ship task only after landing is confirmed.
Chain a teardown or a steer after `bin/fm-pr-merge.sh` only on that script's own exit status (`bin/fm-pr-merge.sh ... && ...`), never after `;` or a pipe, whose status is the last command's: a refused merge exits non-zero, and a steer sent after it tells the worker its PR merged when it did not.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

Release a ship whose only remaining step is the captain's own (fork patch, `docs/fork-decisions.md` 2026-11-09), mirroring the scout release in `scout-completion`: when nothing is left after its PR merges but an action he must take himself - a physical step, a sign-in, a launch on his own machine - the ship's work is done.
Its brief tells it to end its ready `done:` line with `; captain step: <action>` rather than report `ready:` or wait; a ship already waiting on such a step with `blocked [on=captain]` after its merge is the same case, and teardown retires that blocker with its status log.
Land that PR exactly like any other done PR; once landing is confirmed, hold the ship's own row for him with `bin/fm-captain-hold.sh hold <ship-id> --kind arjun-only --reason <the exact action>`, adding what the follow-up would check when one remains, then tear the ship down through `bin/fm-teardown.sh` without waiting for him.
Teardown keeps that row open as his call with the deliverable recorded, and its landed-work and companion gates are unchanged: a ship with any unmerged PR or unlanded work is never released by this rule, and a refusal is investigated, never forced.
When he reports the step done, record his words with `answer <ship-id> --decision-file <path>`; only when work remains after his step, add `--release` and dispatch a fresh short ship whose brief carries them.
A captain call that gates the work before its merge, such as a design choice or a login the change itself needs, still waits on the live worker.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
