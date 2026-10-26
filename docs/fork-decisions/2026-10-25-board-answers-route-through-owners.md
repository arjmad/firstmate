PR: #109

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Board answers route through their owners: a note sent alone never feeds the keyed intake, an inbox item feeds it only for `close`, `hold-until` and `remind-at`, and the intake's `until=` mode defers through the new `fm-captain-hold.sh defer` (re-hold `--until`, never a close; fixes `fm-board-later-closes-hold` for the board); `read` prints each board answer's route | `bin/fm-procevent-lavish.sh` (`cmd_choice_rows`, `cmd_read`), `bin/fm-captain-hold.sh` (`command_defer`, `command_answers`), `docs/captain-hold-lifecycle.md`, `tests/fm-procevent.test.sh`, `tests/fm-captain-hold-lifecycle.test.sh` | same files | carried | 45dd50a5 |
