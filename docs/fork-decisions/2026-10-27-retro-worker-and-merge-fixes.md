2026-10-27: Arjun picked "1 Desktop lock (Recommended), 2+4 Merge plumbing + test, 3 Worker start checks" in a /matt-retro grilling in the Claude desktop session, recorded as brain fact 8887 on systems/platform/firstmate.
Decision: a Claude desktop-app session takes the fleet lock, the helm's own attended merges stop waking it, a CLEAN pull request GitHub refuses once is retried, and workers start without the folder-trust, missing-tool, and missing-report stalls the retro found.
The merge-landed wake for a merge the helm made itself already existed, so that fix suppresses it for attended merges by the main actor; away-posture, branch-actor, secondmate, and poll-observed merges keep their outcome.
The named-pane delivery test and the refused-merge teardown stop were already on main (`tests/fm-spawn-steer-herdr-live-e2e.test.sh`, #90; the delivery-PR gate in `bin/fm-teardown.sh`, #95), so neither carries a code change here.
No upstream proposal.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The Claude desktop engine at `~/.claude/remote/ccd-cli/<version>` is a harness for the session lock | `bin/fm-session-lock-lib.sh` (`fm_harness_path_name`), `tests/fm-session-lock-ancestry.test.sh` | same files | carried | 45dd50a5 |
| An attended merge the main actor makes in a main home queues no merge-landed wake | `bin/fm-merge-outcome-lib.sh` (`fm_merge_outcome_report`), `tests/fm-pr-merge.test.sh` | same files | carried | 45dd50a5 |
| A refused GitHub merge is retried while the pull request reads open and CLEAN at the verified head | `bin/fm-pr-merge.sh` (`github_clean_at_verified_head`, the GitHub merge loop), `tests/fm-pr-merge.test.sh` | same files | carried | 45dd50a5 |
| The direct-PR checks-green brief names a rebase or force-push as a push that needs the gate run again | `bin/fm-dod-lib.sh` (`fm_dod_checks_green_block`) | same file | carried | 45dd50a5 |
| A teardown or steer chained after a merge is gated on the merge's own exit status | `.agents/skills/ship-landing/SKILL.md` | same file | carried | 45dd50a5 |
| Every Pi launch, worker included, carries session-only `--approve` when the executable advertises it | `bin/fm-spawn.sh` (`pi_supports_approve` caller), `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-pi-seeded-home-trust-live-e2e.test.sh`, `.agents/skills/harness-adapters/references/harness/pi.md`, `docs/verification/runtime-backends.md` | same files | carried | 45dd50a5 |
| A pinned Claude worker root missing the session's user MCP servers is named at spawn | `bin/fm-worker-account-lib.sh` (`fm_worker_account_claude_mcp_gap`), `bin/fm-spawn.sh`, `tests/fm-worker-account.test.sh`, `docs/configuration.md` "Worker account pin" | same files | carried | 45dd50a5 |
| A scout `done:` without its report file reads blocked, and the scout brief requires the report even beside another deliverable | `bin/fm-crew-state.sh` (`emit_ship_status_done`), `bin/fm-brief.sh` (scout Definition of done), `tests/fm-crew-state.test.sh` | same files | carried | 45dd50a5 |
