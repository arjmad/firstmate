2026-11-22: Arjun asked in the helm "I thought stow started a fresh session", then picked "Yes, my /stow restarts too (Recommended)" through the native selector.
He then narrowed it in the helm: "I only want it when I type /stow. Not the stow guard".
He then added: "Can we make it so slash stow does the stow as normal and then give me the option for the fresh session".
Decision: a `/stow` the captain types in the Claude helm runs the pass as normal, and after a reset-safe receipt the helm asks him through the native question selector, "Start fresh now" (recommended) or "Keep this session"; only "Start fresh now" restarts it fresh.
The `/stow` the stow guard asks for saves everything and keeps the session, and a receipt that is not reset-safe asks nothing.
This supersedes the offer half of [the helm fresh restart record](2026-11-22-helm-fresh-restart-after-stow.md), whose restart ran only "for a session the guard asked"; the `/clear` refresh mechanics it records are unchanged.
The stow guard gains a UserPromptSubmit mode that records `offer:{sid, at}` in `state/.stow-guard.json` when the lock-holding primary's prompt is `/stow` itself, and its Stop ask no longer offers or records a restart, so the typed `/stow` is the one offer source and `bin/fm-helm-refresh.sh request` stays its one reader.
A typed `/stow quick` records nothing either, because a quick save never claims reset-safe (amended 2026-11-22).
A `/stow` that an agent, a secondmate home or the stow cascade sends records nothing, and every other refusal in `request` is unchanged.
The guard's own ask state (`fired`, `last_stow`, `asked`) is left alone, because a Stop hook cannot tell which turn it ends and that state is what stops a compaction without a stow.
So a typed `/stow` whose own turn ends over the token line still gets the guard's ask and a second pass, as before, and its offer survives it.
A typed offer also stays valid for its TTL across a later guard-asked `/stow`; the skill's question, asked only after a typed `/stow`, is what keeps that `/stow` from restarting.
No upstream proposal yet, for the same reason as the record it amends.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The stow guard's `prompt` mode records the restart offer for a `/stow` the captain types, and its Stop ask records none | `bin/fm-stow-guard.sh` (`prompt` mode, block message), `.claude/settings.json` (UserPromptSubmit registration), `tests/fm-stow-guard.test.sh` (`test_guard_ask_never_offers_a_restart`, `test_typed_stow_records_the_offer` and its two negatives), `tests/fm-stow-guard-prompt-live-e2e.test.sh`, `tests/fm-turnend-guard.test.sh` (tracked grok-guarded entry count), `bin/fm-test-run.sh` (live-harness-optin list), `docs/configuration.md` ("Stow guard"), `docs/scripts.md`, `docs/verification/supervision.md` ("Helm refresh by /clear") | `bin/fm-stow-guard.sh`, `.claude/settings.json`, `tests/fm-stow-guard.test.sh`, `tests/fm-turnend-guard.test.sh`, `bin/fm-test-run.sh`, `docs/configuration.md`, `docs/scripts.md`, `docs/verification/supervision.md` | carried | 9ac0288e |
| The stow skill asks the captain after a reset-safe typed `/stow`, and runs the refresh request only on "Start fresh now" | `.agents/skills/stow/SKILL.md` (completion receipt), `bin/fm-helm-refresh.sh` (header, offer refusals), `tests/fm-helm-refresh.test.sh` (`test_typed_stow_offer_is_accepted`), `tests/fm-helm-refresh-live-e2e.test.sh` (header) | `.agents/skills/stow/SKILL.md` | carried | 9ac0288e |
