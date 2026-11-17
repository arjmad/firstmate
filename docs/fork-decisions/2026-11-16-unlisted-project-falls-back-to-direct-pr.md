2026-11-16: With the no-mistakes pipeline retired (2026-11-10), a ship to a project the registry does not list still resolved to `no-mistakes off`, a pipeline no daemon serves.
Decision: every `bin/fm-project-mode.sh` fallback - no registry, an unlisted project, an unknown mode - resolves to `direct-PR off`; a registered bare entry keeps its legacy `no-mistakes` meaning, since every live registry entry names its mode.
No upstream proposal: upstream still ships the pipeline as its default delivery path.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Registry fallbacks resolve to direct-PR | `bin/fm-project-mode.sh` (header, missing-registry, unlisted, unknown-mode fallbacks), `tests/fm-project-mode.test.sh` | same files | carried | 427056c4 |
