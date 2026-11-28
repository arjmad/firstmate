2026-11-15: Arjun retired the no-mistakes pipeline on 2026-11-10, and in the 2026-11-15 cleanup grill chose "remove" for its install (row 1) and "delete all now" for its data (row 25).
Decision: no-mistakes is not a required tool, so bootstrap neither reports it MISSING nor checks it against a version floor, and the worker brief's shared-infrastructure rule no longer names its daemon.
Without this, bootstrap's MISSING line would prompt a reinstall of the removed binary on every host.
The `.no-mistakes/` gitignore entries, the gate-refuse and watch-arm path patterns, the shared test fake, and CONTRIBUTING.md's maintainer pipeline path stay: they are upstream-shaped and harmless.
No upstream proposal: upstream still ships the pipeline as its default delivery path.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| no-mistakes is not a required tool | `bin/fm-bootstrap.sh` (header, `install_cmd`, `upgrade_cmd`, `COMMON_TOOLS`, `NO_MISTAKES_MIN` and its OUTDATED check), `tests/fm-bootstrap.test.sh` (`make_fake_toolchain`, `test_no_mistakes_not_required`), `tests/fixtures.sh` (floor comment), `docs/configuration.md` (universal requirements, diagnostics), `.agents/skills/bootstrap-diagnostics/SKILL.md` (OUTDATED floors) | same files | conflicted | 9ac0288e |
| The worker brief's shared-infrastructure rule drops the no-mistakes daemon | `bin/fm-brief.sh` (header, `SHARED_INFRA_RULE`) | same file | carried | 9ac0288e |
