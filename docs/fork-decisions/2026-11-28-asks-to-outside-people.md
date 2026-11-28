2026-11-25: Arjun approved audit item cap-23 ("build") at the helm walk of the 2026-11-24 deep audit: an open ask to Sunita or Sapna gets a backlog tag per person, its close tells the asker's side inside the fleet, and both sides can list the open asks with their age.
Decision: the tag is one `Asked: <person> YYYY-MM-DD [<ref>]` body line on the existing row-field machinery, not a new `Owner:` value or a `Batch:` tag.
`Owner:` already answers who moves the row next, which stays `arjun` for a Sunita ask he takes to her and `fleet` for a Sapna ask Nova relays, and `Batch:` holds one tag that a Sunita ask may already need for `place:office`.
The line carries the ask's date, so its age is the age of the ask rather than of the row, and its ref, so the close knows which envelope to settle.
Decision: every close path settles the ask through `bin/fm-asks.sh`: a done or removal through `bin/fm-tasks-axi.sh`, the weekly prune, the teardown close and a closing captain answer.
For Sapna it sends Nova the fleet-handoff skill's settlement (`to-nova --kind reply --reply-to <envelope>`, the sapna-46 rule in the skill's `references/status-and-gotchas.md`) unless Nova already reported that envelope, and it records the settlement so a replayed close never sends it twice.
For Sunita it sends nothing anywhere and names the item to strike on `data/sunita-list.md`; it does not edit that home-private list.
Decision: the list is `fm-tasks-axi.sh list --asked [<person>]`, a `list` so Nova reads Sapna's asks through the skill's read-only `backlog list` with no skills change.
No upstream proposal: Sapna, Sunita, Nova and the fleet-handoff transport are this fleet's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The `Asked:` row line, its people and its value check | `bin/fm-backlog-row-lib.sh` (header, `fm_backlog_row_field_pattern`, `fm_backlog_row_field_label`, `FM_BACKLOG_ASK_PEOPLE`, `fm_backlog_asked_valid`, `fm_backlog_row_field_body_append`) | same file | carried | 427056c4 |
| The open-ask list with age and the settlement a close runs | `bin/fm-asks.sh`, `tests/fm-asks.test.sh` | none (fork-only files) | carried | 427056c4 |
| `asked <id>` records the line, `update` carries it, `list --asked` lists, and done/rm settle the ask after the close | `bin/fm-tasks-axi.sh` (header, usage, `prepare_update_owner`, `command_row_field`, `command_asked`, `read_close_asked`, `settle_close_ask`, the list, done and rm dispatch) | same file | carried | 427056c4 |
| The teardown close and a closing captain answer settle the ask | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_close_reply`), `bin/fm-captain-hold.sh` (`close_answered`, `settle_answered_ask`) | same files | carried | 427056c4 |
| The backlog contract and the scripts table name the line and the command | `docs/task-lifecycle.md` "Backlog contract", `docs/scripts.md` | same files | carried | 427056c4 |
