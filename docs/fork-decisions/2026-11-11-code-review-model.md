2026-11-11: Arjun approved "version 1" of the model setup ("1. lets do version 1") after a report found the merge-gate `/code-review` named no model, so through `claude -p` it ran on his default chat model, Fable 5.2, from 2026-11-09 (13 review runs on Opus on 11-09, 36 on Fable on 11-10), and a flag-less `claude -p` on Fable can bill usage credits without asking.
Decision: the review always runs on a pinned model, read from one line in `<home>/config/code-review-model` and `claude-opus-5-5` when that is absent or empty; the fleet's `fleet-mode` command writes the file and firstmate only reads it.
The brief names only the headless `claude -p --model <model>` route, because an in-session skill call runs on the worker's own session model, which a worker cannot switch.
This supersedes the "in its harness or headless" route in [the 2026-11-10 code-review focus record](2026-11-10-code-review-focus.md), whose row for that step now reads superseded.
A secondmate home inherits the file from the primary.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The ship worker's review step runs `/code-review` headless with `--model` from `config/code-review-model` | `bin/fm-dod-lib.sh` (`fm_dod_code_review_model`, `fm_dod_code_review_block`), `tests/fm-dod-lib.test.sh`, `docs/task-lifecycle.md` (Code review before merge), `docs/configuration.md` (Code review model), `bin/fm-pr-merge.sh` (unreviewed refusal message), `bin/fm-config-inherit-lib.sh` (`FM_INHERITABLE_CONFIG`) | `bin/fm-dod-lib.sh` (`fm_dod_code_review_block`), `docs/task-lifecycle.md`, `docs/configuration.md`, `bin/fm-pr-merge.sh`, `bin/fm-config-inherit-lib.sh` | carried | c8d8fdad |
