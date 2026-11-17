2026-11-17: Arjun answered "Do both" at the helm on the 2026-11-17 self-improvement review, relayed by the main firstmate, which takes its recommendation R2.
Decision: a noticed item is routine by default, and it is held for him only when its filing names one of his four kinds of call: ask-first, ruling, retire or machinery.
A `--now` item still reaches him that turn, held or not, and his ask-first rules still bind the fleet's fix of a routine item.
This changes how rule 1 of [2026-11-11-calls-grouped-by-what-it-takes](2026-11-11-calls-grouped-by-what-it-takes.md) is filed, not the rule: a hold was the default and `--routine` opted out, and now routine is the default and `--call` opts in.
Why: since the 2026-11-11 rule, 36 of 56 noticed rows were filed held, and the 2026-11-16 sweep had to release 13 of them; the default now enforces his rule in code rather than in a weekly clean-up.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `file` files a noticed item routine unless `--call ask-first\|ruling\|retire\|machinery` holds it, records the kind in the hold reason, holds an open unheld noticed row filed again with `--call`, says when a routine reopen lifted the captain hold the row closed with, refuses `--call` on an idea, and keeps `--routine` as a no-op for older callers | `bin/fm-noticed.sh` (`cmd_file`, `hold_reason`), `tests/fm-noticed.test.sh`, `.agents/skills/noticed-queue/SKILL.md` (Filing, Acting first) | none (fork-only script and skill) | carried | 427056c4 |
