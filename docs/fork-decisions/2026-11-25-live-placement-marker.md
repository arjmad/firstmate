2026-11-25: Arjun approved deep-audit items a1-39 and a1-40 at his helm walk of the 2026-11-24 audit ("add the live marker (x-02 ruling kept)"): a live business op, or a task that needs state only the main home reaches, had no way to say so, so every such spawn under a `first` placement rule needed a `--placement-override` described as a captain redirect.
Decision: `bin/fm-brief.sh --live <reason>` writes one `Placement: live - <reason>` line under a ship or scout brief's `# Setup`, and `bin/fm-spawn.sh` reads it, fence-aware, before the placement probe, skips the probe, and records `placement=live` and `placement_reason`.
A secondmate spawn, a second live line, or `--placement-override` beside it is refused; a relaunch keeps the recorded placement rather than refusing, because every relaunch of a live task still carries the line.
`--placement-override` now reads as a reason this task must run here (a captain redirect or a Heimdall-only need).
No upstream proposal yet: the `first` placement rule is itself fork-only.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A brief's live placement line places a fresh ship or scout in this home without the placement probe | `bin/fm-brief.sh` (`--live`), `bin/fm-dod-lib.sh` (`fm_brief_live_placements`), `bin/fm-spawn.sh` (placement gate, task record, header), `bin/fm-intake-spill.sh` (header), `docs/configuration.md` "Intake spill", `docs/task-lifecycle.md` intake, `tests/fm-brief.test.sh`, `tests/fm-spawn-placement.test.sh` | `bin/fm-brief.sh`, `bin/fm-dod-lib.sh`, `bin/fm-spawn.sh`, `docs/configuration.md`, `tests/fm-brief.test.sh` | carried | 9ac0288e |
