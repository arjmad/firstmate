2026-10-31: Arjun took the recommended option on the Launchpad 0.2 review board's first item: every call held for him carries its own two or three choices and the recommended one, recorded when firstmate or a worker asks.
Decision: `hold` records the choices, the recommendation, and an optional one-line question on the hold reason's existing kind prefix, and Bearings and Launchpad read them from there; a call with none shows a single Open action rather than an invented Done.
Why: Launchpad's Work rows all showed a generic Done (recommended) or Start because no held row recorded its choices, so tapping one answered nothing.
The kind prefix is the carrier because choices belong to one call, so they must die with its reason the way the kind and default already do.
No upstream proposal: hold kinds, defaults, and their prefix are this fork's own patch (2026-10-14).

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `hold --options`, `--recommend`, and `--ask` record a call's choices on its reason prefix, `choices` sets them on an active hold, `defer` keeps them, and a default refuses `;` | `bin/fm-captain-hold.sh` (`validate_hold_choice_args`, `parse_hold_kind_prefix`, `command_hold`, `command_choices`, `command_defer`), `tests/fm-captain-hold-kind.test.sh` | none (fork-owned hold-kind code) | carried | 45dd50a5 |
| The keyed-answer intake records a pick whose answer or shown label names a recorded choice as `Choice picked:` | `bin/fm-captain-hold.sh` (`picked_choice`, `command_answers`) | `command_answers` (keyed-answer intake) | carried | 45dd50a5 |
| Bearings board rows carry a captain hold's recorded `choices` | `bin/fm-bearings-snapshot.sh` (`hold_choices`), `tests/fm-bearings-snapshot.test.sh` | board row projection | carried | 45dd50a5 |
| Briefs ask a worker's `needs-decision` line for its choices and recommendation, and the hold and Bearings skills use them | `bin/fm-brief.sh`, `.agents/skills/captain-hold-lifecycle/SKILL.md`, `.agents/skills/bearings/SKILL.md`, `docs/captain-hold-lifecycle.md` | crewmate rule 6 wording | carried | 45dd50a5 |
