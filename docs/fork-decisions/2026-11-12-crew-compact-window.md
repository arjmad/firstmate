2026-11-12: Arjun, asked in the helm selector whether workers' 1M context windows are optimal, picked "At 400K (Recommended)" for where workers compact.
The evidence he saw: 178 Claude worker sessions over 3 days had a median peak context of 189K, a p90 of 377K, 1 in 11 over 400K, and a maximum of 764K, and workers never compacted because they launched with no compaction window while the helm's own launch line carries `CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000`.
Decision: a home's `config/crew-compact-window` holds one token count, and every Claude ship and scout launches with `CLAUDE_CODE_AUTO_COMPACT_WINDOW` set to it, on a spawn, a relaunch, and a Herdr resume; this home sets 400000.
The file is inherited into secondmate homes, so the second mate's workers compact at the same window.
An invalid file refuses the launch, so a home that declares a window never starts a worker without it.
Claude Code 2.1.319 accepts the variable from 100k to 1M tokens and ranks it above the `autoCompactWindow` setting.
No upstream proposal: the window is this fleet's tuning.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A Claude ship or scout launches with the home's compaction window and records it as compact_window= | `bin/fm-spawn.sh` (header, `launch_template` claude `__CLAUDECOMPACT__`, `COMPACT_WINDOW` resolve, task record, spawned line, `preserve_relaunch_meta`), `tests/fm-spawn-dispatch-profile.test.sh` | same files | carried | c8d8fdad |
| A Claude ship or scout launches with the home's compaction window and records it as compact_window= | `bin/fm-exclude-tools-lib.sh` (`fm_crew_compact_window_check`), `bin/fm-control.sh` (relaunch precheck), `tests/fm-control-relaunch.test.sh` | same files | carried | c8d8fdad |
| A Claude ship or scout launches with the home's compaction window and records it as compact_window= | `bin/fm-config-inherit-lib.sh` (`FM_INHERITABLE_CONFIG`), `docs/configuration.md`, `docs/agent-control.md`, `.agents/skills/operational-home-layout/SKILL.md`, `.agents/skills/harness-adapters/references/harness/claude.md` | same files | carried | c8d8fdad |
