2026-10-26: Arjun, at the helm, adopted the pstack usage pass's recommendations (`data/pstack-usage-pass/report.md`, "ok i agree with all of you recommendations for pstack"), after it found the `/poteto` skill still spawning Fable 5.1 xhigh against his 2026-10-13 crew-dispatch line, and 7 bug-fix ships since that date dispatched without the method.
Decision: a poteto-mode worker takes its model and effort from `config/crew-dispatch.json` like any other ship (nothing on Fable until he says), replacing the Fable 5.1 xhigh spawn profile of the [2026-10-03 `/poteto` dispatch](2026-10-03-poteto-helm-dispatch-poteto-mode-brief.md).
The [2026-10-13 standing opt-in](2026-10-13-standing-poteto-mode-opt-task-class.md) widens from bug-fix ships to four ship classes `data/captain.md` records: a bug fix, something slow, a live problem with no obvious cause, and restructuring shared code.
Intake classifies every ship against those classes, and on a host with the method's entry skill `bin/fm-brief.sh` warns after writing the brief, without refusing, when a ship id reads as one of them and no `--method` is given.
The mode keeps the name `poteto-mode` and its five-seat panel; the ten typed `pstack-<name>` commands live in the skills store.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `/poteto` spawns on the model and effort `config/crew-dispatch.json` picks instead of Fable 5.1 xhigh, and its standing opt-in names four ship classes | `.agents/skills/poteto/SKILL.md`, `README.md` | `README.md` | carried | 45dd50a5 |
| A ship scaffolded without `--method` whose task id reads as a standing poteto-mode class gets a stderr warning, and intake names the check | `bin/fm-brief.sh` (method validation, ship scaffold report, header), `docs/task-lifecycle.md`, `tests/fm-brief.test.sh` | `bin/fm-brief.sh`, `docs/task-lifecycle.md`, `tests/fm-brief.test.sh` | carried | 45dd50a5 |
