# claude (VERIFIED; busy signature re-verified 2026-07-25 on Claude Code 2.1.220, running-shell footer added 2026-07-27 on the same build)

| Fact | Value |
|---|---|
| Busy-pane signature | Two verified shapes. (1) Streaming turn: the harness-scoped `…[[:space:]]+\([0-9]+[smh]` shape after a rotating glyph and word, for example `✢ Pollinating… (16s · ...)`; legacy `esc to interrupt` remains accepted. (2) Long-running foreground shell tool call, where generation is idle but the crew is working: `<glyph> <past-tense word> for <duration> · N shell(s) still running`, for example `✻ Cooked for 10m 17s · 1 shell still running`. |
| Running-shell footer invariants | Only the SHAPE is invariant. Both the glyph and the past-tense word rotate: glyphs observed live include `✻` `✽` `✶` `✳` and a bare middot; words observed include Cooked, Brewed, Cultivating, Puttering, Boogieing, Improvising. Leading whitespace is optional, whitespace on both sides of `·` is required, and the line end is unanchored so trailing hints (for example `· ctrl+o to expand`) still match. Never match on one glyph or one word. |
| Idle controls | `✻ Worked for 31s` is idle (no shell clause). The completed-shell summary `Thought for 9s, ran 1 shell command` is idle: it lacks `still running`, which is the clause that separates a live shell from a finished one. |
| Running-shell footer freshness boundary | The two streaming shapes are self-fresh - they exist only while a turn streams and are overwritten each animation tick. The running-shell footer is grafted onto a persistent past-tense turn summary, so a killed or wedged harness can leave it frozen on screen and a single-capture regex read would report `working` forever, suppressing exactly the recovery paths that gate on a not-busy verdict (`bin/fm-watch.sh`'s stale block and its `.stale-since` timer, `bin/fm-supervise-daemon.sh`'s wedge escalation). The footer is therefore deliberately NOT in `FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT`, the single-sample signature every reader shares through `fm_busy_lines_match`. `FM_TMUX_CLAUDE_SHELL_BUSY_REGEX_DEFAULT` is read only by `fm_busy_shell_footer_line`, which `fm_busy_decide` uses to compare the matched footer LINE across two samples, so unrelated churn elsewhere in the tail cannot refresh a frozen footer and a reader that cannot re-read the pane never sees the signature at all. False-stale is the deliberately preferred direction over false-healthy. `FM_BUSY_FOOTER_RECHECK_SECS` tunes the gap (default 2s; `0` means no freshness proof is taken, so the footer is simply not credited). |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

Herdr's native agent state reads idle for that whole running-shell span, the case `docs/herdr-backend.md` "Current transport behavior" owns.
That is why the pane text stays the corroborating source for a claude crew blocked on its own long-running foreground tool call (`bin/fm-crew-state.sh`, `crew_pane_is_busy`).

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it from an active firstmate session using `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, unless `FM_HOME` is already set to the active firstmate home; verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim/faint SGR 2 ghost runs before pending-input classification on both ANSI-capable readers (tmux and herdr).
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in `docs/herdr-backend.md` "Composer and injection safety", with active captures in `docs/verification/runtime-backends.md`.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204; Stop-owned auto-arm revalidated 2026-08-02, Claude Code 2.1.220).**
This is separate from the per-task crewmate turn-end hook described in [`../SKILL.md`](../SKILL.md) (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: first the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), then `bin/fm-turnend-guard.sh --claude`, and exiting the guard with status 2 plus stderr reliably forces the model to continue; `docs/turnend-guard.md` owns why the auto-arm must dispatch first.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake; the model drains and handles wakes but never runs a routine re-arm command.
`docs/watcher-continuity.md` owns lock identity across ordinary, takeover, and restarted-session Stop-hook lanes.

## Primary session-start nudge

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.

## Primary watcher supervision

Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`.

## no-mistakes skill invocation

- claude: `/<skill>`, for example `/no-mistakes`.
