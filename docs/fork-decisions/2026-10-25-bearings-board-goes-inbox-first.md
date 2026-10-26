PR: #109

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The bearings board goes inbox first, Arjun's grill and approved mockup on 2026-10-25: inbox items with 2-3 item-specific actions, value boxes and Send note, folding sections remembered per viewer, decision cards opened on their recommendation with Take all recommendations, and a compact fleet strip with step bars and outcome sentences; `build` validates the extended v1 payload and `--if-changed` skips an unchanged heartbeat rebuild | `.agents/skills/bearings/assets/board-template.html`, `bin/fm-bearings-board.sh` (`validate_payload`, `inbox_item_gaps`, `command_build`), `.agents/skills/bearings/SKILL.md` (Lavish board mode, board wake, heartbeat refresh), `AGENTS.md` section 8 heartbeat line, `tests/fm-bearings-board.test.sh`, `tests/fm-bearings-board-render.test.sh`, `tests/assets/board-render-harness.mjs` | same files | carried | 45dd50a5 |
