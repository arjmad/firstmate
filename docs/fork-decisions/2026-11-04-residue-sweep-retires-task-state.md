2026-11-04: Arjun approved a batch of routine cleanup fixes on 2026-10-21, and this one came from it.
Tasks that ended without a teardown kept their steering inbox, hooks directory, and Herdr presentation journal forever, and an acknowledged inbox kept the task live for the sweep.
Empty watch-arm captures from killed arms also piled up, because the scratch rotation did not know their prefix.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The startup residue sweep retires a retired task's inbox, hooks directory, and closed-workspace presentation journal, counts an inbox live only while it holds an unhandled steer, and rotates orphaned watch-arm captures while no live watcher holds the lock | `bin/fm-state-residue-sweep.sh` (`collect_referenced`, `sweep_task_state`, `rotate_scratch`), `tests/fm-state-residue-sweep.test.sh` | `bin/fm-state-residue-sweep.sh`, `tests/fm-state-residue-sweep.test.sh` | carried | 31b2bfaa |
