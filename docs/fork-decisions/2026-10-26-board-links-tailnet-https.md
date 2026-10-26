PR: #119

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Board links the captain is given use the tailnet HTTPS origin `tailscale serve` publishes for Lavish's port, because Chrome on Arjun's phone forces https for ts.net names, retro 2026-10-26 candidate 13 as routed after Arjun's pick: `fm-lavish-url.sh` rewrites a session URL from the live serve config and passes anything else through, the bearings build and Atlas board link go through it, and Lavish's saved URL stays raw | `bin/fm-lavish-url.sh`, `tests/fm-lavish-url.test.sh` | `bin/fm-bearings-board.sh` (`establish_board_session`, header), `bin/fm-atlas.sh` (`file`, header), `bin/fm-brief.sh` (`LAVISH_LINE`), `.agents/skills/bearings/SKILL.md`, `docs/scripts.md`, `tests/lib.sh`, `tests/fm-atlas.test.sh` | carried | 45dd50a5 |
