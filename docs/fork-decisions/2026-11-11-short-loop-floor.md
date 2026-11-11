2026-11-11: Arjun ruled in a helm grilling walk-through that every worker carries the short-loop floor, answering "Every worker (Recommended)".
Decision: every generated ship and scout brief, on every harness, opens its Definition of done with five steps: state the goal and the smallest change, reproduce a defect before changing code, prove the change where it runs, do a comment pass on the diff, and report what was not proven.
A poteto-mode brief leaves the floor out, because that method already runs these steps; a promoted scout always gets it, since promotion demotes the method to context.
No upstream proposal yet: the floor follows Arjun's own working method.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Short-loop floor text | `bin/fm-dod-lib.sh` (`fm_dod_short_loop_block`), `tests/fm-dod-lib.test.sh` | same file | carried | c8d8fdad |
| Ship and scout briefs carry the floor unless poteto-mode | `bin/fm-brief.sh`, `tests/fm-brief.test.sh` | same file | carried | c8d8fdad |
| Promoted scouts carry the floor | `bin/fm-promote.sh` | same file | carried | c8d8fdad |
