2026-10-27: Arjun, in the proactivity-audit grilling in the Claude workspace session, settled how agents become proactive without drifting off task (brain facts 8944, 8990, 9027 and 9064 on `systems/platform/firstmate`).
Decision: a problem an agent notices outside its task, and an idea that could improve the ecosystem, become backlog captain holds kind `noticed` or `idea`, filed only by firstmate, deduplicated, and never dispatched until he picks.
Workers jot observations in task-local notes and leave at most one `Noticed:` and one `Idea:` line at the end; firstmate shows each noticed item once, the Monday open-items sweep re-checks them and flags any still broken after a week, and a Monday ranking with Atlas's rule shows him the top 3 new ideas once.
One read-only exploration scout a week rotates over Amazon and Walmart program changes, upstream tool features, and business-data blind spots; its findings reach him only through idea capture and the top 3.
Why: his stated pain (backlog S6) is wanting agents to take initiative and bring good ideas, while every extra ping and mid-task detour costs him attention.
The worker's lines live at fixed paths (the scout report, or `data/<id>/notes.md` for a ship) that teardown reads, rather than a path the completion status names, so collection needs no status-line protocol and still reads nothing beyond the task's own records.
No upstream proposal: the queue rides this fork's Atlas and captain-hold machinery.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The noticed and idea queue: `fm-noticed.sh` files captain holds kind noticed or idea, attaches evidence to a duplicate, reopens a recurring noticed item, never re-asks an answered idea, collects a finished task's lines, records the Monday top 3, and keeps the not-yet-shown list | `bin/fm-noticed.sh`, `tests/fm-noticed.test.sh`, `.agents/skills/noticed-queue/SKILL.md`, `.agents/skills/agent-skill-trigger-index/SKILL.md`, `docs/documentation-audiences.json`, `docs/scripts.md`, `bin/fm-test-run.sh` | none (new files and registrations) | carried | 45dd50a5 |
| The wake drain prints a NOTICED section of items no captain reply has shown yet | `bin/fm-wake-drain.sh` (`print_noticed_section`, `print_status_sections`) | `print_status_sections` | carried | 45dd50a5 |
| Teardown prints the one noticed and one idea line a finished task left | `bin/fm-teardown.sh` (after `backlog_refresh_reminder`), `tests/fm-teardown.test.sh` | teardown's final report | carried | 45dd50a5 |
| Ship and scout briefs carry a "Noticed and ideas" section | `bin/fm-brief.sh` (`NOTICED_SECTION`) | the ship and scout brief templates | carried | 45dd50a5 |
