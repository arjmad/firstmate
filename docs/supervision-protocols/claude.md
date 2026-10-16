Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`), never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle with no model command and no model tokens.
   An actionable close wakes you through the hook's exit-2 rewake, delivered as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
4. On the one `Stop hook feedback` automatic-mechanism failure notice (`firstmate watcher auto-arm FAILED ...`), drain, inspect the automatic mechanism failure, and do not turn the notice into a repeating manual-arm loop.
5. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and watcher startup path before ending blind.
   Keep the Stop-owned automatic mechanism as the only Claude arm owner.
6. Treat `watcher: started ...` and `watcher: attached ...` inside automatic arm output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a rewake and the next Stop-launched arm, while the bounded turn-end guard prevents a blind Stop when recovery did not start.
   No PreToolUse hook denies fleet commands based on watcher status.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. The turn-end guard (`bin/fm-turnend-guard.sh --claude`) remains the final backstop.
   It requires the PID-strict live-watcher and fresh-beacon predicate at the Stop boundary, except for the Claude-specific foreign-live-owner safe exit owned by [`turnend-guard.md`](../turnend-guard.md#guard-predicates); that document also owns the distinct model-aware mid-turn pull-guard rules.
   Otherwise, it allows the stop when a watcher is healthy or an open auto-arm generation claim owns recovery, while fresh failure epochs advance the bounded one-time attended fail-open progression described there.
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.
10. `AskUserQuestion` holds the turn open until the captain answers, and with no turn end nothing re-arms.
    While supervision is needed, `bin/fm-question-pretool-check.sh` allows it only for a present captain (his newest prompt or question answer in this session is within ten minutes) on a home whose keeper can keep the supervision host parked behind the open question ([supervision-host.md](../supervision-host.md#while-a-captain-question-is-open)), and denies it otherwise.
    While the question is open the host keeps handling the wakes it may take and holds every close for you; when the question closes, the held closes arrive in that same turn as one `Stop hook feedback` wake, handled as in step 3.
    When it is denied, ask in the turn's final message instead and end the turn; the answer arrives as an ordinary captain message.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook foregrounds on a home that opted out of the [supervision host](../supervision-host.md) (`config/supervision-host-off`).
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract and the Claude ownership model.
