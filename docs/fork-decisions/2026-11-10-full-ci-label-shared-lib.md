2026-11-10: Arjun, answering the subtraction-pass board card "Full CI on firstmate changes that touch a shared library script", chose "Use the full-ci label".
Decision: a worker whose firstmate change touches a shared library script, a `bin/fm-ci-plan.sh` `full_trigger` path under `bin/` or `tests/`, adds the existing `full-ci` label to its pull request; every other pull request keeps the affected-shard run.
Why: the "CI is the proof" ruling (`2026-11-10-firstmate-ci-is-the-proof.md`) assumed a full CI run, and the label makes the full run visible on the pull request and keeps every later push full.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A worker adds the `full-ci` label when its change touches a shared library script | `.agents/skills/firstmate-coding-guidelines/SKILL.md` (Repo style rules) | `.agents/skills/firstmate-coding-guidelines/SKILL.md` | carried | cdba9315 |
