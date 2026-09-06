# Test evidence: upstream a913539 merge + tests/assets mapping fix (16965fa)

Branch fm/firstmate-upstream-integration, base 2e9afce, target 16965fa.

## Regression reproduced then fixed (tests/assets mapping)
- changed-list-before-fix.log: with the merge-commit runner (4655e0c), `bin/fm-test-run.sh --list --changed --base 2e9afce` on the merged tree exits 2 with "no changed-test mapping for source path: tests/assets/board-render-harness.mjs".
- changed-list-merged-tree.log: same command with the fixed runner (16965fa) exits 0 and lists the asset's consumer tests/fm-bearings-board-render.test.sh.
- fm-test-run-colocated-before-fix.log: the new colocated case is red on the pre-fix runner ("not ok - shared test asset selects the script that names it").
- fm-test-run-colocated.log: `bin/fm-test-run.sh tests/fm-test-run.test.sh` on the fixed runner, all cases ok, including per-script selection (fm-bearings-snapshot in the same family is not widened in).
- fm-bearings-board-render.log: the real asset consumer passes on the merged tree.

## Fork commits preserved
- a61864a: the five Google Workspace files are byte-identical to a61864a (git diff --quiet), and fm-google-workspace.log shows tests/fm-google-workspace.test.sh passing on the merged tree.
- 2e9afce: every added line in tests/fm-public-followup.test.sh, tests/fm-backlog-handoff.test.sh, and tests/fm-bootstrap-network-parallel.test.sh is present in HEAD; fm-bootstrap-network-parallel.log shows the conflict-resolved rendezvous test passing; fm-public-followup.log shows the clock-derived fixture suite.

## Conflict resolutions verified through the runner
- family-coverage-lanes.log: pure-contract-unit lists both fm-google-workspace.test.sh and fm-rovo-harness.test.sh; `--check-coverage` ok (total=183 serial=146 serial_shards=5 serial_unhinted=6); five serial shards with 29/28/29/30/30 scripts.
- Hint table: 140 hints; every HEAD hint equals max(upstream a913539, fork 2e9afce); 29 raised from the fork; only fm-backend-herdr-focus-flash-e2e dropped.
- shard-weights.log: shard weights computed from the merged table match docs/fm-test-portable-shards.md exactly (857784/857781/857779/857766/857779 ms, imbalance 18 ms).
- scheduled-order.log: fm-public-followup schedules first (longest hint).

## History
- Merge commit 4655e0c has parents 2e9afce and a913539 (--no-ff); 85ad5e7 is not an object in this repository, so it is not merged.

## Public follow-up suite result
- fm-public-followup.log: 53 cases ok, including every clock-derived fixture case from 2e9afce; then the remote-collect case fails with "command is not tracked by the configured remote root: fm-public-followup-collect.sh", the host-environment failure the intent documents (bin/fm-remote-entrypoint.sh unsets HOME while this host's git config sets core.excludesFile to a tilde path, so `env -u HOME git ls-files` fails). Not introduced by the merge, and not fixed in this PR per the intent.
