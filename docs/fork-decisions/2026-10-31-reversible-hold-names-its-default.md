2026-10-31: Arjun picked the ecosystem board's `captain-asks-cut` card as a Keep in the helm chat on 2026-10-30 ("show the sweep list for approval before anything closes; 72h defaults after") and said on 2026-10-31 to start it.
Decision: every new reversible captain call carries a default that applies after 72 hours, using the existing `hold --default` release rather than a new mechanism.
Why: 72 asks had piled up waiting on him, and a reversible hold without a default never released itself, so a call the fleet could have settled on its recommendation kept waiting on him.
A missing default stays possible for calls with no option that is safe to apply unasked, such as an idea or an open question, but it is now an explicit `--no-default` rather than an omission.
No upstream proposal: hold kinds and default release are this fork's own patch (2026-10-14).
Superseded 2026-11-01: Arjun [dropped the default release](2026-11-01-drop-default-release.md), so a reversible hold names no default and `--no-default` is refused.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `hold --kind reversible` refuses to write unless it carries `--default`, the captain's own `--until` deferral, or an explicit `--no-default`; `--no-default` is refused beside `--default` or with any other kind | `bin/fm-captain-hold.sh` (`validate_hold_kind_args`, `command_hold`), `tests/fm-captain-hold-kind.test.sh`, `.agents/skills/captain-hold-lifecycle/SKILL.md`, `docs/captain-hold-lifecycle.md` | none (fork-owned hold-kind code) | superseded by #PRNUM | 45dd50a5 |
| The noticed queue and Atlas hold their items with `--no-default`, so an idea never picks itself | `bin/fm-noticed.sh` (`cmd_file`), `bin/fm-atlas.sh` (`cmd_file`) | none (fork-owned scripts) | superseded by #PRNUM | 45dd50a5 |
