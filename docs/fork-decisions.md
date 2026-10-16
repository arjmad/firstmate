# Fork decisions

2026-10-07: The fleet load baseline in `~/code/skills/docs/agent-load-baseline-2026-10-07.md` measured this repo's `AGENTS.md` at 29,144 characters plus about 11,000 characters of `.agents/skills` descriptions, the heaviest always-loaded item in the fleet.
Decision: no further fork-side shrink of `AGENTS.md` and no upstream proposal.
`AGENTS.md` and `bin/` are not identical to upstream: `AGENTS.md` still carries the earlier fork-side reduction from commit 3220f742 and is 226 lines shorter than upstream `main`, and 41 `bin/` files differ from upstream `main`, 38 of them through fork-only changes since the last upstream sync.
The fleet's own guidance load is measured by the skills store's `scripts/agent-load` instead.

2026-10-10: Arjun's 2026-10-07 dispatch phase 5 asked for narrow work to default to low effort and judgment to high, and for each task record to carry the typed dispatch verdict (rule, confidence, profile) so low-confidence picks are visible and tunable.
The private, gitignored `config/crew-dispatch.json` already encodes the effort split: rule 3 sends narrow bounded work to Opus 5.5 at low effort, rule 4 sends judgment work to Opus 5.5 at high effort, and the default is high.
Recording the verdict on each task record would need `bin/fm-dispatch-resolve.sh` or `bin/fm-spawn.sh` to write task metadata, which is a `bin/` change.
Decision: the effort split lives in the private config, and the verdict is not recorded automatically.
`bin/fm-dispatch-resolve.sh` prints the typed verdict at intake, and firstmate copies it into the task body by hand when it matters.
No `bin/` change and no upstream proposal.
Reopen this if upstream adds a dispatch-verdict field to task records.

2026-10-14: Arjun approved ecosystem-review change 1 under decision D2 in the helm: "Do it on the fork only."
Firstmate carries exactly three fork patches for authority mechanics, with no upstream proposal: captain-hold kinds with a 72-hour default release, the `ready` and `gate-wait` worker states, and dependent-repository slots named at dispatch with `--also`.
Nothing beyond those three is authorized by this decision.
The table below carries one row per patch.

2026-10-16: Arjun decided, reviewing the 2026-10-15 ecosystem audit, that while a question to him is unanswered firstmate keeps working everything else and only the item that needs his answer waits, over defaulting after a timeout or alerting only.
The audit found the Claude helm parked on one open `AskUserQuestion` from 2026-10-15 05:21Z to 13:04Z: the selector holds the turn open, a Claude primary's supervision re-arms only at a turn end, and a supervision host that handed main a wake has stopped its own cycle, so no wake was handled.
Decision: a fork-only PreToolUse guard denies the blocking question tool in a primary home whose fleet needs supervision and tells the helm to ask in its final message and end the turn; an idle home keeps the selector.
It was chosen over letting the supervision host handle wakes during a blocked turn, which would need a new host mode and a second wake consumer racing main, and over guidance alone, because supervision infrastructure prefers deterministic enforcement to agent memory (`firstmate-coding-guidelines`), with the rule still stated in `AGENTS.md` section 9.
No upstream proposal.

## Fork patches

2026-10-10: Arjun withdrew the 2026-09-25 rule that firstmate cleanup findings are upstream candidates.
Firstmate fixes land in this fork as ordinary PRs, and this table tracks each one as a fork patch so its carry across upstream syncs stays visible.

Contract:
Every fork PR that changes upstream-owned files adds one row naming what changed, where, and the upstream code it touches.
Every upstream-sync PR re-checks each row against the merged upstream and updates its status and last-checked sync.
Status is `carried` when the change still applies and upstream is unchanged there, `upstreamed` when upstream now has an equivalent so the fork change can be dropped at the next sync, or `conflicted` when upstream changed the same code and the merge needed a hand.
A sync drops a fork change only when its row reads `upstreamed`, and the captain's merge of that sync PR is the approval.

The seed covers the fork-only commits in `git log --no-merges upstream/main..origin/main` at upstream `main` 1a868710, grouped by change.
The upstream-merge commits (95b30d7d, #21, #34) and the fork-decisions-only docs commits (#66, #67, #71) are syncs or fork-owned prose and carry no row.
PR cells without a number name the commit.

| Date | PR | What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-30 | #2, #18, #31 | Per-account Google Workspace access, account table in gitignored config, pinned MCP launcher | `bin/fm-google-workspace*.{sh,py}`, `docs/google-workspace-access.md` | `bin/fm-test-run.sh`, `README.md`, `AGENTS.md`, `docs/configuration.md`, `docs/scripts.md` | carried | 24f3a6b8 |
| 2026-08-30 | #3, #33 | Derive public follow-up fixture expiries from the clock | `tests/fm-public-followup.test.sh` and siblings | `bin/fm-test-run.sh`, `bin/fm-ensure-agents-md.sh`, `.github/workflows/ci.yml` | conflicted | 24f3a6b8 |
| 2026-09-07 | #5 | Recover a Herdr pane whose agent exited but left a stale registration | `bin/backends/herdr.sh` | `bin/backends/herdr.sh`, `docs/herdr-backend.md` | carried | 24f3a6b8 |
| 2026-09-07 | 3c4ab14e, 93c312b0, 33239369, f0dfb7f4, 45de66ef, #45, #47 | Pool-slot allocation records: descendant Pi isolation, refusal on mutation only, no orphan endpoint, contested and stale record retirement, slot leases | `bin/fm-allocation-lib.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-install-treehouse.sh`, the leased-slot fake in `tests/secondmate-helpers.sh` | those plus `bin/fm-backend.sh`, `bin/fm-bootstrap.sh`, `bin/fm-wake-lib.sh`, `.pi/extensions/fm-primary-*.ts`, `docs/architecture.md` | conflicted | 24f3a6b8 |
| 2026-09-07 | #8 | Retire a torn-down task's queued Pi branch wake rows | `.pi/extensions/lib/fm-branch-dispatch.ts` | same file, `docs/pi-supervision-branch.md` | carried | 24f3a6b8 |
| 2026-09-07 | 27cc2b65, #15, dc6e03fc, d5645ec1, #6192 | Fork CI: sharded shell lint, bounded serial shards, 13 GiB lint bound, portable group packing budget | `.github/workflows/ci.yml` | `.github/workflows/ci.yml`, `bin/fm-test-run.sh`, `docs/fm-test-portable-shards.md` | conflicted | 24f3a6b8 |
| 2026-09-08 | #10, #57 | Standard tier by default, quota at every dispatch intake, quota read from the pinned Claude account | `bin/fm-dispatch-resolve.sh`, `bin/fm-quota-snapshot.sh`, `bin/fm-spawn.sh` | those plus `AGENTS.md`, `.agents/skills/quota-array-dispatch`, `harness-adapters` dispatch reference | conflicted | 24f3a6b8 |
| 2026-09-11 | a22a33f4, 05037e4a, 373de9df | Reconcile fork spawn preflight, ps probe and `--changed` fixture mapping with upstream tests | `bin/fm-spawn.sh`, `bin/fm-test-run.sh` | same files | carried | 24f3a6b8 |
| 2026-09-12 | #19 | Drop the Require no-mistakes PR check | `.github/workflows/no-mistakes-required.yml` (removed) | that workflow, `CONTRIBUTING.md`, `bin/fm-test-run.sh` | carried | 24f3a6b8 |
| 2026-09-12 | #14 | Preserve a correct `CLAUDE.md -> AGENTS.md` symlink | `bin/fm-ensure-agents-md.sh` | same file, `docs/scripts.md` | carried | 24f3a6b8 |
| 2026-09-12 | #16, #60 | Bound stale wakes, count a live worktree gate as progress, loud broken clones, confirmed acks, teardown `--help` | `bin/fm-watch.sh`, `bin/fm-classify-lib.sh`, `bin/fm-wake-drain.sh` | those plus `bin/fm-fleet-sync.sh`, `bin/fm-teardown.sh`, `docs/configuration.md` | carried | 24f3a6b8 |
| 2026-09-12 | #17, cec25ad7 | Confirm Claude Code's exit dialog so exit and relaunch finish | `bin/fm-control-lib.sh`, `bin/fm-control.sh` | same files, `harness-adapters` Claude reference, `docs/agent-control.md` | conflicted | 24f3a6b8 |
| 2026-09-17 | #23 | Claude PostToolUse progress hook for the busy-age bound | `bin/fm-spawn.sh` | same file, `AGENTS.md`, `harness-adapters` Claude reference | conflicted | 24f3a6b8 |
| 2026-09-17 | #24 | Sweep gone endpoints' watcher records at locked session start | `bin/fm-state-residue-sweep.sh` | `bin/fm-session-start.sh`, `bin/fm-bootstrap.sh`, `bin/fm-backend.sh`, `bin/fm-watch.sh`, `AGENTS.md` | carried | 24f3a6b8 |
| 2026-09-19 | 3220f742, f88abdfb, #51 | Reduced always-loaded guidance, selected delivery paths, precedence pointer and cd guard name | `AGENTS.md` | `AGENTS.md`, `CONTRIBUTING.md`, `docs/task-lifecycle.md`, `harness-adapters` dispatch reference | conflicted | 24f3a6b8 |
| 2026-10-01 | #39, #62 | Fast-forward configured live checkouts and make merged work go live | `bin/fm-fleet-sync.sh`, `bin/fm-pr-merge.sh` | those plus `bin/fm-bootstrap.sh`, `bin/fm-watch.sh`, `.agents/skills/ship-landing`, `docs/configuration.md` | conflicted | 24f3a6b8 |
| 2026-10-01 | #40, #49, a00d0c27, 09cb0c5c | Brief carve-outs for fleet-memory filing, research scouts filing to the brain, brain MCP tools only | `bin/fm-brief.sh`, `bin/fm-promote.sh`, `bin/fm-dod-lib.sh` | same files | carried | 24f3a6b8 |
| 2026-10-01 | #44 | Preserve Pi calm transcript captures with Pi 1.0 | `harness-adapters` Pi reference | same file | carried | 24f3a6b8 |
| 2026-10-01 | #43 | Resolve `fm_exec_timed`'s owner without `BASHPID` on bash 3.2 | `bin/fm-timeout-lib.sh` | same file | carried | 24f3a6b8 |
| 2026-10-01 | #42, #52 | Workspace-cleanup documentation drift and fork-only skill line fixes | `.agents/skills/*`, `docs/*` | `bootstrap-diagnostics`, `harness-adapters`, `agent-skill-trigger-index`, `project-management`, `quota-array-dispatch` skills | carried | 24f3a6b8 |
| 2026-10-03 | #48 | `/poteto` helm dispatch with a poteto-mode brief method | `.agents/skills/poteto`, `bin/fm-brief.sh`, `bin/fm-dod-lib.sh` | `bin/fm-brief.sh`, `bin/fm-dod-lib.sh`, `README.md`, `docs/task-lifecycle.md` | conflicted | 24f3a6b8 |
| 2026-10-04 | #50 | Fix red portable serial 2 and serial 9 | `tests/fm-calm-pi-extension.test.sh`, `tests/fm-pi-branch-extension.test.sh`, `tests/fm-supervision-host.test.sh` | same tests | carried | 24f3a6b8 |
| 2026-10-04 | #53 | Keep a failed at-turn hand-back from reading as a dead host | `bin/fm-supervision-host.sh` | same file | carried | 24f3a6b8 |
| 2026-10-04 | #54 | Judge the PR's forge head when `fm-pr-merge` records the PR | `bin/fm-pr-check.sh` | same file | carried | 24f3a6b8 |
| 2026-10-04 | #55 | Answer a blocked Monitor with the one-live-cycle rule | `bin/fm-subagent-pretool-check.sh` | same file, `docs/subagent-guard.md` | carried | 24f3a6b8 |
| 2026-10-04 | #56 | Answer a repeated branch wake ack as already acknowledged | `bin/fm-wake-drain.sh`, `bin/fm-wake-grant.sh` | same files, `docs/watcher-continuity.md` | carried | 24f3a6b8 |
| 2026-10-04 | #58 | Let Claude primaries cd once the harness resets the shell cwd | `bin/fm-cd-pretool-check.sh` | same file, `.claude/settings.json`, `docs/cd-guard.md` | carried | 24f3a6b8 |
| 2026-10-06 | #61 | Refuse holds that re-cite a superseded captain ruling | `bin/fm-tasks-axi.sh` | same file, `captain-hold-lifecycle` and `stow` skills | carried | 24f3a6b8 |
| 2026-10-06 | #65, #70 | Keep Lavish server restarts from waking board owners, `--process-exit` preset | `bin/fm-procevent-lavish.sh`, `bin/fm-procevent.sh`, `bin/fm-procevent-when.sh` | same files, `.agents/skills/process-event-sources` | carried | 24f3a6b8 |
| 2026-10-10 | #72 | Serialize concurrent Herdr recoveries with the resume lock-wait opt-in | `tests/fm-backend-herdr-presentation-e2e.test.sh` | same test | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/common/control-and-recovery.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/common/dispatch.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/common/model-and-effort.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/common/primary-hooks.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/agy.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/cursor.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/gemini.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/grok.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/kimi.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/omp.md` | same file | conflicted | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/harness-adapters/references/harness/pi.md` | same file | conflicted | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/fmx-respond/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/quiet/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/secondmate-provisioning/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/captain-hold-lifecycle/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/updatefirstmate/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/operational-home-layout/SKILL.md` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `.agents/skills/decision-hold-lifecycle/SKILL.md` (removed) | same file | carried | 24f3a6b8 |
| 2026-10-11 | #76 | Correct stale references from the prompt audit | `docs/documentation-audiences.json` | same file | carried | 24f3a6b8 |
| 2026-10-11 | #77 | Refuse a raw `gh pr merge`, `gh-axi pr merge`, or `gh api` merge call in a primary home, naming `fm-pr-merge.sh` | `bin/fm-merge-pretool-check.sh`, `bin/fm-merge-command-policy.mjs`, `.grok/hooks/fm-primary-merge-check.json`, `.opencode/plugins/fm-primary-merge-check.js`, `docs/merge-guard.md` | `.claude/settings.json`, `.codex/hooks.json`, `.cursor/hooks.json`, `.pi/extensions/fm-primary-turnend-guard.ts`, `.omp/extensions/fm-primary-turnend-guard.ts`, `bin/fm-test-run.sh`, `docs/scripts.md`, `docs/turnend-guard.md`, `docs/arm-pretool-check.md` | carried | 24f3a6b8 |
| 2026-10-13 | #79, #80 | Pin the Pi package CI installs to 1.2.0, the version Heimdall runs, with `--before` freezing its caret-ranged sibling packages at 1.2.0 | `.github/workflows/ci.yml` | same file | carried | 24f3a6b8 |
| 2026-10-13 | #78 | Standing poteto-mode opt-in by task class from `data/captain.md` (bug-fix ships) | `.agents/skills/poteto`, `docs/task-lifecycle.md`, `README.md` | `docs/task-lifecycle.md`, `README.md` | carried | 24f3a6b8 |
| 2026-10-14 | #82 | Captain-hold kinds (`--kind` reversible or arjun-only), a reversible `--default` that releases itself after 72 hours as the decision of record, and the watcher's hourly `release-due` tick | `bin/fm-captain-hold.sh` (`hold`, `release-due`), `bin/fm-hold-reason-lib.sh` (`fm_hold_reason_decode`), `bin/fm-watch.sh` (`hold_release_tick`), `tests/fm-captain-hold-kind.test.sh` | `bin/fm-captain-hold.sh`, `bin/fm-watch.sh`, `.agents/skills/captain-hold-lifecycle`, `docs/captain-hold-lifecycle.md`, `docs/configuration.md`, `tests/fm-watch-triage.test.sh` | carried | 24f3a6b8 |
| 2026-10-14 | #82 | Worker states `ready` (open PR waiting to land, never a decision) and `gate-wait` (CI or policy gate) as declared waits; `ready` is captain-relevant | `bin/fm-classify-lib.sh` (`status_is_paused`, `status_is_captain_relevant`, verb vocabulary), `bin/fm-crew-state.sh` (`log_state_note`), `bin/fm-brief.sh` (status rules), `bin/fm_voice_records.py` (`STATE_VERBS`) | those files, `.agents/skills/ship-landing`, `docs/architecture.md`, `tests/fm-watch-triage.test.sh`, `tests/fm-crew-state.test.sh`, `tests/fm-brief.test.sh` | carried | 24f3a6b8 |
| 2026-10-14 | #82 | Dependent-repository companion worktrees: `--also <repo>` on the brief and spawn, companion PRs recorded and merged under the same task, companion slots checked and returned at teardown | `bin/fm-brief.sh` (`--also`), `bin/fm-spawn.sh` (`spawn_take_companion_slot`, `spawn_list_companion_worktrees`), `bin/fm-teardown.sh` (companion safety and return), `bin/fm-pr-check.sh` (`--also`), `bin/fm-pr-merge.sh` (companion mode), `tests/fm-also-companion.test.sh` | those files, `tests/lib.sh` (`fm_fake_treehouse_pool` `get --lease`), `tests/fm-teardown.test.sh`, `tests/fm-pr-merge.test.sh`, `tests/fm-brief.test.sh`, `.agents/skills/ship-landing`, `docs/task-lifecycle.md`, `docs/scripts.md` | carried | 24f3a6b8 |
| 2026-10-16 | #83 | Deny a blocking captain question (`AskUserQuestion`) in a primary home with fleet work under way, so supervision keeps re-arming at turn end | `bin/fm-question-pretool-check.sh`, `tests/fm-question-pretool-check.test.sh`, `tests/fm-question-pretool-check-live-e2e.test.sh` | `.claude/settings.json`, `AGENTS.md` section 9, `docs/supervision-protocols/claude.md`, `bin/fm-test-run.sh`, `docs/scripts.md`, `docs/verification/runtime-backends.md`, `tests/fm-turnend-guard.test.sh` | carried | 24f3a6b8 |
