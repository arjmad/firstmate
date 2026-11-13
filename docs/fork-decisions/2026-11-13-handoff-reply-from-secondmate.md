2026-11-13: The main firstmate released the 2026-11-13 idea row for dispatch under Arjun's standing rule that the fleet fixes reversible idea rows that pay off.
A handoff row moved to a secondmate closed in that home, which holds no handoff note, so its sender got no scripted reply.
Decision: the main home answers that note from the mate's terminal line on its parent channel, through the same `close-reply`, on every watcher poll.
A failed line answers as removed, and a done line that carries a PR waits for that PR's merged line.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `close-handed-off` answers a moved row's handoff note from the secondmate's merged, child outcome, inactive outcome, or item-keyed done or failed line | `bin/fm-inbox.sh` (header, `load_classify_lib`, `handoff_note_id`, `cmd_close_reply`, `note_field`, `strip_outcome_fields`, `handed_off_outcome`, `cmd_close_handed_off`, `unreplied_handoff_rows` comment, dispatch), `tests/fm-inbox.test.sh` | same files | carried | c8d8fdad |
| The watcher poll runs `close-handed-off` while anything is handed off | `bin/fm-watch.sh` (`handed_off_reply_tick`, the poll loop), `tests/fm-watch-triage-pause.test.sh` (`test_secondmate_merged_line_answers_a_moved_handoff`) | same files | carried | c8d8fdad |
| The handed-off marker comment names its new reader | `bin/fm-backlog-handoff.sh` (`mark_handed_off` comment) | same file | carried | c8d8fdad |
