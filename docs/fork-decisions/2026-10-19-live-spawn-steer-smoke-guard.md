PR: #90

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Live spawn-and-steer smoke guard: a real Claude worker spawned through `fm-spawn` on Herdr in a named lab, steered idle through `fm-send`; selected by `--changed` for launch, naming, and composer code; `fm-live-lab.sh forget-claude` for its trust cleanup | `tests/fm-spawn-steer-herdr-live-e2e.test.sh`, `bin/fm-live-lab.sh` (`cmd_forget_claude`) | `bin/fm-test-run.sh` (family, timing, changed-file map), `bin/fm-live-lab.sh`, `tests/fm-live-lab.test.sh`, `firstmate-coding-guidelines`, `docs/herdr-backend.md`, `docs/verification/runtime-backends.md` | carried | 45dd50a5 |
