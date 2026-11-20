2026-11-20: Arjun approved audit finding a7-15 in his deep-audit helm walk: five members of one board and several one-place errands were filed without a `Batch:` tag, so he saw them as separate calls against his 2026-11-10 and 2026-11-11 grouping rules.
Decision: a call can be tagged when it is filed, and filing a call that has no tag and would show as taking his own hands, or linking an untagged call to a board, warns; nothing is refused, because a call with its own outside deadline stays its own call.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `hold --batch place:<name>\|board:<task-id>` records the row's `Batch:` line; a new untagged call with no `--options` (not an idea or noticed item, not a call whose back-on date passed, and not `bin/fm-tasks-axi.sh`'s filing hold) warns on stderr naming `--batch`, and `board-link` warns for each linked call with no tag, naming `fm-tasks-axi.sh batch <id> board:<origin>` | `bin/fm-captain-hold.sh` (`command_hold`, `command_board_link`), `tests/fm-captain-hold-kind.test.sh` | `bin/fm-captain-hold.sh` | carried | 427056c4 |
