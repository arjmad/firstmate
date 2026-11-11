2026-11-11: Arjun ruled in the helm chat that the fleet drains its two Claude accounts in two stages, and said "Yes add the rule" for the both-low case and "Build it now in this account".
His reason: "We should really switch over when we are at 0%, but ... I don't want to run out of usage or something. And then we're stuck at 0%. ... Really, we just want to manage usage between our two accounts well."
The quota watch (jobs repository) moves the helm launch line, the worker pins and the unattended calls at 3 percent of the running account's week when the other account is open, and Cade and Nova at 1 percent; it writes `drain.json` for firstmate to read.
Decision: the helm hands itself over when its launch line names another account: at its next idle moment it runs `/stow`, a detached waiter ends it with SIGTERM once no spawn, teardown or merge holds a task lock, and the home's configured start command (the fleet's `helm-autostart` on Heimdall) starts a fresh helm after the session lock frees; Arjun gets one line naming the account to pick in the Claude app.
This replaces his 2026-11-10 "Arjun restarts the helm himself"; with no start command configured the helm still only reports the move.
The helm does not hand over while an away or quiet record exists, because neither mode's contract lets a helm end itself; the wake waits for the mode to end.
Decision: when both accounts are low, firstmate starts no Claude ship or scout and routes them to the home's spill profile, Pi on the Codex subscription.
This is the one case that overrides two standing rules: "never hold dispatch to save quota" (the dispatch reference) and "no GPT workers unless he names them" (Arjun 2026-09-24/2026-10-06, `config/crew-dispatch.json`); his "Yes add the rule" is the authority.
The spill ships off (`both_low_spill=off`): the main firstmate turns it on only after one real Pi ship on the Codex subscription passes end to end on Heimdall (main firstmate, 2026-11-11, replacing the build brief's local proof because Fafnir's Pi has no Codex sign-in).
The capability marker is `~/.local/state/firstmate/helm-handover.json`, written by firstmate and only read by the quota watch (main firstmate, 2026-11-11).
No upstream proposal: the two-account drain, its quota watch and the start command are this fleet's own.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Account drain: move check, helm handover, both-low answer, capability marker | `bin/fm-account-drain.sh`, `tests/fm-account-drain.test.sh` | none (fork-owned script) | carried | c8d8fdad |
| Session start records the helm's account | `bin/fm-session-start.sh` (locked side-band step) | same file | carried | c8d8fdad |
| Spawn refuses a Claude ship or scout while both accounts are low, and names an account handover holding the task set | `bin/fm-spawn.sh` | same file | carried | c8d8fdad |
| The `account-handover` task-set lock role | `bin/fm-wake-lib.sh` (`fm_lock_set_role`) | same function | carried | c8d8fdad |
| Dispatch routes ships and scouts to the spill profile while both accounts are low | `.agents/skills/harness-adapters/references/common/dispatch.md` | same file | carried | c8d8fdad |
| `config/account-drain` schema | `docs/configuration.md` | same file | carried | c8d8fdad |
