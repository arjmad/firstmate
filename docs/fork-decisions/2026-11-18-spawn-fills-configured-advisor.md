2026-11-18: Arjun, at the helm, asked that Claude ship and scout workers carry the Fable advisor every time ("don't restrict the usage"), then narrowed the change to the spawn fix ("Do the bug fix only").
Decision: when a fresh Claude ship or scout launch omits `--advisor` while `config/crew-dispatch.json` is active, `fm-spawn.sh` applies the advisor that config gives it, so a hand-typed launch after an ambiguous resolution no longer drops it; an explicit `--advisor default` still launches with none.
This extends the [2026-11-14 advisor decision](2026-11-14-claude-advisor.md), which applied the advisor only when firstmate passed it by hand.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| An omitted --advisor on a Claude ship or scout takes the clear dispatch selection's advisor, else the one advisor every advisor-capable claude profile agrees on; a batch forwards an explicit --advisor default | `bin/fm-spawn.sh` (header, batch `shared_args`, dispatch-record advisor fill), `tests/fm-spawn-dispatch-profile.test.sh`, `docs/configuration.md` | `bin/fm-spawn.sh` | carried | 9ac0288e |
