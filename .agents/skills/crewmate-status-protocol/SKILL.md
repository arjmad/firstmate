---
name: crewmate-status-protocol
description: >-
  Read by path when a crewmate or scout brief's Rules point here: before a worker's first pause, gate-wait, ready, or captain-only status line, before it resolves its own blocker or wait, and before it starts or stops a process or touches a worktree pool.
user-invocable: false
metadata:
  internal: true
---

# Crewmate status protocol

Your brief's Rules carry each rule as one line; this file holds what those lines mean in practice.
Where your brief and this file differ, your brief wins.
The pause, gate-wait, and ready verbs below are the ones your brief's States list names.

## Waits

Use the pause state - distinct from `blocked:` - when deliberately waiting for work or an external condition expected to clear on its own, including your own validation round.
Before ending your turn with your own background shell or monitor still running, or before waiting on your own pipeline run or a long foreground command, append a pause line naming the job and its completion condition.
Name what you are waiting for and what will let you resume; do not repeat the declaration on every poll.
Do not declare active implementation or reasoning as a wait.
Firstmate may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
When you know when the wait clears, include `until <YYYY-MM-DDTHH:MMZ>` (UTC) for a recheck at that time; for your own background job or command with a timeout, that time is its start plus its timeout, rounded up to the minute.
Follow the resolution rule below when the wait clears, then resume the task.
Use the gate-wait state instead when the wait is a CI run or a policy gate (a required check, a review requirement, a merge queue) that clears without anyone deciding anything; it releases your attention exactly like a pause and is never a `needs-decision`.

## Blockers and the captain

Use `blocked:` when you are stuck and need help.
When only the captain himself can clear that blocker or answer that question (he must act, sign in, or choose), add the `[on=captain]` tag before the colon, as in `blocked [on=captain] [at=<epoch>]: {what he must do}`; that tag, not your wording, puts the wait in his inbox.

## Ready and captain steps (ship tasks)

Use the ready state with `PR {url}` when your PR is open and ready to land but your task continues after it merges, such as a step that needs the merged code or a companion PR that must land first.
You may not merge it, and landing it is firstmate's under the project's merge posture, so a PR waiting to land is never a `needs-decision`; when nothing remains for you once it is open, report `done:` under the Definition of done instead.
A step only the captain can take himself once your PR merges (an action on his own hands or machine, such as linking an account or a launch only he can run) is not a reason to report ready or to wait as `blocked [on=captain]`: end the `done:` line the Definition of done names with `; captain step: {the exact action}` and stop, even when the PR has already merged; firstmate lands the PR, holds that step for him and releases you, and his answer starts a fresh ship for anything left after it.

## Closing a decision, blocker, or wait

A decision or blocker on your status log stays open until a `resolved` line carrying its exact key lands or you declare `done:` or `failed:`, which clears every open one, firstmate's included; a later `working:` line never closes it.
So declare `done:` only once every decision you raised was answered or no longer needs an answer; `failed:` is always available for an unrecoverable failure.
Firstmate's reply normally writes that `resolved` line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved [at=<epoch>]: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.

## Shared infrastructure

Two things are shared with every other lane.

The worktree pool your own worktree came from, and the repository every lane's worktree shares.
Never create, remove, return, prune, move, or reassign a worktree or pool slot, and never write into a sibling slot's directory.
Removing a worktree is administration rather than an edit outside your directory, and it lands on lanes that are running right now.
The act is the rule and commands are only examples of it - `treehouse` get/return/remove/prune, the equivalent operations on any other worktree provider or runtime backend, and `git worktree add|remove|move|prune`.
A slot that looks unused is not evidence that it is free, and returning your own worktree is firstmate's job at cleanup, not yours.

The processes on this host: live services and other lanes' agent sessions run beside yours, often under the same user and with the same command line as a scratch copy you start.
Stop only what you started, by the pid you recorded when you started it.
Record it in the same command that starts the process, because `$!` does not survive into a later tool call, and start it as its own process group so its children stop with it: `(set -m; <command> & echo $! > <pidfile>)`.
To stop it, check that `ps -o args= -p <pid>` still shows the command you launched, then run `kill -- -<pid>`.
Stopping something through its own handle is also fine: your harness's stop for its own background task, `docker compose down` for your compose project, or a `kill-server` on the tmux socket you created.
Never stop anything by name or command-line pattern - `pkill`, `killall`, `pkill -f`, or `kill $(pgrep ...)` - because the same pattern matches live services and other agents, and stopping one restarts or ends work you do not own.
