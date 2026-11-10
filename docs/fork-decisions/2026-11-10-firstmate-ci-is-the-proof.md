2026-11-10: Arjun, in the helm chat, shown two shapes for one check per change (the local pass is the proof, or CI is the proof and the worker runs only tests near its change), answered "yes i want it as two builds", taking CI as the proof for the firstmate repository first.
Decision: a worker on a firstmate change runs only `bin/fm-test-run.sh --near` before pushing, and the pull request's CI is the proof; a wider local run is only for reproducing a CI lane or switching on a gated live guard.
The merge gate is unchanged: `bin/fm-pr-merge.sh` still refuses a red or unreported check, and every push, a review fix included, runs the branch's whole CI plan again.
Why: a worker ran the 95 suites that call `bin/fm-spawn.sh` locally for about two hours, and CI then caught three broken fixtures that run had missed (https://github.com/arjmad/firstmate/pull/226).
The repository is public, so its GitHub-hosted Actions minutes are not billed: the account's November usage shows 47,275 Linux and 1,231 macOS minutes for firstmate at a net cost of 0.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `bin/fm-test-run.sh --near` selects the suites named for each changed file plus the `--changed` suites of a backend family no CI lane installs | `bin/fm-test-run.sh` (`changed_paths`, `family_ci_unexercised`, `select_near`, header), `tests/fm-test-run.test.sh` | `bin/fm-test-run.sh` (`select_changed`, mode parsing, automatic concurrency) | carried | c8d8fdad |
| The local pre-push test policy names `--near` and CI as the proof | `CONTRIBUTING.md` (Development), `.agents/skills/firstmate-coding-guidelines/SKILL.md` (Repo style rules, launch-code guard) | `CONTRIBUTING.md` (Development), `.agents/skills/firstmate-coding-guidelines/SKILL.md` | carried | c8d8fdad |
| A ship's definition of done runs the local checks the repository's contribution guide names before pushing and before the Sol loop | `bin/fm-dod-lib.sh` (`fm_dod_code_review_block`, `fm_dod_block` direct-PR) | `bin/fm-dod-lib.sh` (`fm_dod_block` direct-PR) | carried | c8d8fdad |
