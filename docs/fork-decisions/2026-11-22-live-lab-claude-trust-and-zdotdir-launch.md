PR: #296

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The spawn-and-steer live guard registers Claude workspace trust for its lab home through `bin/fm-claude-trust.sh --lab-home`, in the worker's store, so Claude Code 2.1.328's "Adding a new directory" dialog does not park the worker, and the 2.1.328 result is recorded | `tests/fm-spawn-steer-herdr-live-e2e.test.sh` (header, lab-home trust before `in_lab`), `docs/verification/runtime-backends.md` (Claude Code 2.1.328 spawn-and-steer observation) | `tests/fm-spawn-steer-herdr-live-e2e.test.sh`, `docs/verification/runtime-backends.md` | carried | 9ac0288e |
| The supervision-host live guard launches its lab primary from a `ZDOTDIR` `.zshenv` passed on the workspace's `--env`, not a command typed into the interactive pane shell, and fails naming `ZDOTDIR` when the pane shell never runs it | `tests/fm-supervision-host-herdr-live-e2e.test.sh` (lab setup `zdotdir/.zshenv`, `start_primary`) | `tests/fm-supervision-host-herdr-live-e2e.test.sh` (`start_primary`) | carried | 9ac0288e |
