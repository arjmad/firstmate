2026-11-22: Arjun asked in the helm "I thought stow started a fresh session", then picked "Yes, my /stow restarts too (Recommended)" through the native selector.
Decision: a `/stow` the captain types in the Claude helm restarts it fresh after a reset-safe receipt, exactly as after the stow guard's own ask.
This amends [the helm fresh restart record](2026-11-22-helm-fresh-restart-after-stow.md), whose restart ran only "for a session the guard asked".
The stow guard gains a UserPromptSubmit mode that records the same `offer:{sid, at}` in `state/.stow-guard.json` when the lock-holding primary's prompt is `/stow` itself, so one script still writes the offer and `bin/fm-helm-refresh.sh request` stays its one reader.
A `/stow` that an agent, a secondmate home or the stow cascade sends records nothing, and every other refusal in `request` is unchanged.
No upstream proposal yet, for the same reason as the record it amends.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The stow guard's `prompt` mode records the restart offer for a `/stow` the captain types | `bin/fm-stow-guard.sh` (`prompt` mode), `.claude/settings.json` (UserPromptSubmit registration), `tests/fm-stow-guard.test.sh` (`test_typed_stow_records_the_offer` and its two negatives), `tests/fm-stow-guard-prompt-live-e2e.test.sh`, `bin/fm-test-run.sh` (live-harness-optin list), `docs/configuration.md` ("Stow guard"), `docs/scripts.md`, `docs/verification/supervision.md` ("Helm refresh by /clear") | `bin/fm-stow-guard.sh`, `.claude/settings.json`, `tests/fm-stow-guard.test.sh`, `bin/fm-test-run.sh`, `docs/configuration.md`, `docs/scripts.md`, `docs/verification/supervision.md` | carried | 427056c4 |
| The stow skill runs the refresh request after a captain-typed `/stow` too | `.agents/skills/stow/SKILL.md` (completion receipt), `bin/fm-helm-refresh.sh` (header), `tests/fm-helm-refresh.test.sh` (`test_typed_stow_offer_is_accepted`) | `.agents/skills/stow/SKILL.md` | carried | 427056c4 |
