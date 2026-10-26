2026-10-24: Arjun asked in the helm for a progress bar in the Claude desktop app showing how far along the helm and workers are, and on the scout report (`data/fleet-progress-view-scout/report.md`) chose "Build it" (a Claude Code mod band in desktop sessions on Heimdall) and "Claude task list" as the source of step progress.
Decision: firstmate carries the data half as one fork patch: `bin/fm-progress.sh`, a read-only projection beside `bin/fm-crew-state.sh` that the fleet repository's band mod polls; Claude ship and scout launches with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`; and one brief line asking workers to keep their plan in the task list, or a `[step=n/m]` status token on other harnesses.
The mod itself lives in the fleet repository, not here.
No upstream proposal.
