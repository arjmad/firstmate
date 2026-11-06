2026-11-06: Arjun picked "Land green captures automatically" on the audit board's nova-autoland card, widening the capture landing of the 2026-10-27 [capture PR land command](2026-10-27-capture-pr-land-command.md) record.
A green Nova skill-capture note now lands without a firstmate turn: its `Land it:` arguments run through `bin/fm-capture-land.sh`, whose own guards and `bin/fm-pr-merge.sh`'s still decide, and only a failed or unfinished land reaches firstmate.
Why: the runtime audit of 2026-11-05 counted 20 to 48 `[nova-skills]` notes a day, each a main-session turn spent running the note's one command by hand.
The grant covers the subject tags a home lists in its `config/capture-autoland`; the main firstmate arms it in its home with `printf '%s\n' '[nova-skills]' >> config/capture-autoland`, and removing the line or the file withdraws it.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `fm-capture-autoland.sh` lands an opted-in green capture note through `fm-capture-land.sh`, acknowledging it on success and announcing it with the failure otherwise | `bin/fm-capture-autoland.sh`, `tests/fm-capture-autoland.test.sh`, `docs/scripts.md`, `docs/configuration.md` (live checkouts) | none | carried | 45dd50a5 |
| `fm-inbox.sh note` hands a note `fm-capture-autoland.sh take` claims to its lander instead of announcing it, and `announce --why` puts a reason ahead of the note's summary in the wake | `bin/fm-inbox.sh` (`finish_note_result`, `cmd_announce`, header) | `bin/fm-inbox.sh` (`finish_note_result`, `cmd_announce`, header) | carried | 45dd50a5 |
