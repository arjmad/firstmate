PR: #93

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Split the watch-triage suite by family into five scripts so each fits well inside the 1500 s per-script bound, with measured serial hints; the serial lane gains a tenth shard because the measured hints filled all nine | `tests/fm-watch-triage-stale.test.sh`, `tests/fm-watch-triage-wait.test.sh`, `tests/fm-watch-triage-wedge.test.sh`, `tests/fm-watch-triage-hold.test.sh`, `tests/watch-triage-helpers.sh` | `tests/fm-watch-triage.test.sh`, `bin/fm-test-run.sh` (family, serial hints, `PORTABLE_SERIAL_SHARDS`), `bin/fm-test-isolation-proof.sh`, `tests/fm-test-isolation-proof.test.sh`, `.github/workflows/ci.yml` (serial matrix), `CONTRIBUTING.md`, `docs/fm-test-portable-shards.md`, `docs/captain-hold-lifecycle.md`, `docs/verification/runtime-backends.md` | carried | 45dd50a5 |
