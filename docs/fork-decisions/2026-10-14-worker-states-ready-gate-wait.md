PR: #82

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Worker states `ready` (open PR waiting to land, never a decision) and `gate-wait` (CI or policy gate) as declared waits; `ready` is captain-relevant | `bin/fm-classify-lib.sh` (`status_is_paused`, `status_is_captain_relevant`, verb vocabulary), `bin/fm-crew-state.sh` (`log_state_note`), `bin/fm-brief.sh` (status rules), `bin/fm_voice_records.py` (`STATE_VERBS`) | those files, `.agents/skills/ship-landing`, `docs/architecture.md`, `tests/fm-watch-triage.test.sh`, `tests/fm-crew-state.test.sh`, `tests/fm-brief.test.sh` | carried | 45dd50a5 |
