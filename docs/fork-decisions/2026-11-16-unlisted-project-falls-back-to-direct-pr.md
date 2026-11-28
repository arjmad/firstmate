2026-11-16: With the no-mistakes pipeline retired (2026-11-10), a ship to a project the registry does not list still resolved to `no-mistakes off`, a pipeline no daemon serves.
Decision (firstmate crewmate, under Arjun's 2026-11-11 standing rule to fix noticed rows under +yolo): every `bin/fm-project-mode.sh` fallback - no registry, an unlisted project, an unknown mode - resolves to `direct-PR off`; a registered bare entry keeps its legacy `no-mistakes` meaning, since every live registry entry names its mode.
No upstream proposal: upstream still ships the pipeline as its default delivery path.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Registry fallbacks resolve to direct-PR | `bin/fm-project-mode.sh` (header, missing-registry, unlisted, unknown-mode fallbacks), `bin/fm-spawn.sh` (downgrade-notice comment), `bin/fm-dod-lib.sh` (comment), `docs/task-lifecycle.md` (intake), `tests/fm-project-mode.test.sh`, `tests/fm-task-delivery.test.sh`, `tests/fm-secondmate-safety.test.sh` | same files | carried | 9ac0288e |
