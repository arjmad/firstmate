2026-11-04: Arjun asked firstmate to fix the near-timeout `Behavior portable serial 4` lane, which ran 20-29 of its 30 minutes on green fork runs.
The serial hints had fallen far below fork CI durations, and the refreshed hints total about 243 minutes, which the coverage guard accepts under its 20-minute budget only at thirteen shards.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Serial hints refreshed from five green fork runs, and thirteen portable serial shards | `bin/fm-test-run.sh` (`PORTABLE_SERIAL_SHARDS`, `portable_serial_weight_hints`), `.github/workflows/ci.yml` (`tests-portable-serial` matrix), `docs/fm-test-portable-shards.md`, `CONTRIBUTING.md` | `bin/fm-test-run.sh`, `.github/workflows/ci.yml` | carried | 957bd124 |
