2026-11-26: Arjun approved the audit 11-24 fixes, including item x-12 (Sol finding S6 in https://github.com/arjmad/fleet/pull/1254): remote jobs ran lavish-axi and impeccable with their telemetry opt-outs unset.
Decision: `bin/fm-remote-job-worker.sh` passes `LAVISH_AXI_TELEMETRY` and `IMPECCABLE_NO_TELEMETRY` to its `env -i` child exactly when they are nonempty in the worker's environment, as it does `USER` and `LOGNAME`.
No upstream proposal yet: the opt-outs serve this fleet's tool set.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Pass the telemetry opt-outs to remote-job children when set | `bin/fm-remote-job-worker.sh` (`child_env`), `bin/fm-remote-job-lib.sh` (header), `tests/fm-remote-job.test.sh` (probe job, identity-unset fixture) | `bin/fm-remote-job-worker.sh`, `bin/fm-remote-job-lib.sh`, `tests/fm-remote-job.test.sh` | carried | 9ac0288e |
