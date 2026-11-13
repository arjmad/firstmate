2026-11-12: Arjun asked in the helm for good handoffs between firstmate, Jade, Cade, Nova and the second mate.
An audit of the fleet-handoff lanes found every lane delivers but replies get lost: 4 of 15 handoffs closed with no reply, a notice reply has no reader, and a relay confirmation wakes the helm for nothing.
Decision: scripts publish the return leg, as the secondmate lane already does.
Closing or removing a backlog row that a handoff filed writes that handoff's reply when nobody wrote one, `unread` resurfaces a day-old acknowledged handoff with no reply and no open row, and a relay confirmation is saved acknowledged so it wakes nobody.
A notice is acknowledged only, because nothing reads a reply to one.
The agent side (status leading with the reply, report answering the hand-on's origin note, report on a reply envelope using `note --acknowledged`) lives in the skills repository's `fleet-handoff`.
No upstream proposal: the handoff request ids are this fleet's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `note --acknowledged` saves a note into handled/ with no wake; `close-reply` answers a closed row's handoff note; `unread` lists acknowledged handoff notes with no reply and no open row | `bin/fm-inbox.sh` (header, `NOTE_DEST`, `queue_note`, `publish_from_reservation`, `cmd_note`, `record_reply`, `cmd_reply`, `cmd_close_reply`, `unreplied_handoff_rows`, `cmd_unread`), `tests/fm-inbox.test.sh` | same files | carried | c8d8fdad |
| `done` and `rm` answer the row's handoff note; `rm` takes `--reason`; `FM_HANDOFF_CLOSE_REPLY` turns it into removed or skip | `bin/fm-tasks-axi.sh` (header, `--reason`, `close_reply`, the done/rm dispatch), `tests/fm-tasks-axi.test.sh` | same files | carried | c8d8fdad |
| Teardown's close answers the row's handoff note, except a forced teardown | `bin/fm-backlog-transition-lib.sh` (`FM_BACKLOG_LIB_DIR`, `fm_backlog_close_transition`, `fm_backlog_close_reply`), `bin/fm-teardown.sh` (`FM_HANDOFF_CLOSE_REPLY=skip` under `--force`), `tests/fm-teardown.test.sh` (`test_teardown_closes_the_backlog_item_itself`, `test_teardown_force_close_writes_no_handoff_reply`) | same files | carried | c8d8fdad |
| The weekly prune's drop answers a handoff as removed, not done | `bin/fm-backlog-prune.sh` (drop loop) | same file | carried | c8d8fdad |
| A handoff row moved to a secondmate is recorded so `unread` does not list it | `bin/fm-backlog-handoff.sh` (`mark_handed_off`, both success paths), `tests/fm-backlog-handoff.test.sh` (`test_handoff_wakes_live_local_receiver`) | same files | carried | c8d8fdad |
| A fleet-handoff notice is acknowledged without a reply | `.agents/skills/noticed-queue/SKILL.md` (step 3) | none (fork-only skill) | carried | c8d8fdad |
