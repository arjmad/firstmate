2026-11-06: Arjun picked the audit-board card "data-scratch (rule half)" after the 2026-11-05 Heimdall runtime audit found about 1.9 GB of firstmate's `data/` was clean repository and brain clones, `node_modules`, and tool binaries that the 60-day rule would either upload to Drive or keep forever.
Decision: teardown deletes a task's reproducible scratch from `data/<id>/` - nested checkouts with nothing uncommitted, stashed, or unpushed, `node_modules`, and ELF or Mach-O tool binaries - instead of archiving it, keeps and names any checkout holding unlanded work, and leaves text and every other file to the 60-day rule.
The one-time delete of the existing scratch was Arjun's separate call and is not part of this rule.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Teardown deletes the reproducible scratch in a task's `data/<id>/` (clean pushed nested checkouts, `node_modules`, tool binaries), keeping and naming checkouts with unlanded work, with a `--dry-run` listing | `bin/fm-data-scratch-prune.sh`, `tests/fm-data-scratch-prune.test.sh` | `bin/fm-teardown.sh` (header, final cleanup step), `tests/fm-teardown.test.sh`, `bin/fm-test-run.sh` (pr-forge family, changed-file map, serial hint), `docs/configuration.md`, `docs/scripts.md` | carried | 45dd50a5 |
