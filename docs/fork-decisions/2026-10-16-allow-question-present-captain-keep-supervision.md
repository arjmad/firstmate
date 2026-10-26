PR: #85

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Allow that question for a present captain and keep supervision running behind it: the question keeper hook, the host's hold and hand-over, and the mirror's captain-presence read | `bin/fm-question-keeper.sh`, `bin/fm-question-lib.sh`, `bin/fm-supervision-host.sh` (`question_hold`, `hold_close`, `handover_exit`, `FM_SUPERVISION_HOST_ARM_OWN_GROUP`), `bin/fm-host-mirror.sh` (`captain-epoch`), `tests/fm-question-keeper-live-e2e.test.sh` | `bin/fm-question-pretool-check.sh`, `.claude/settings.json`, `AGENTS.md` section 9, `docs/supervision-protocols/claude.md`, `docs/supervision-host.md`, `docs/scripts.md`, `docs/verification/supervision.md`, `bin/fm-test-run.sh`, `tests/fm-supervision-host.test.sh`, `tests/fm-question-pretool-check.test.sh`, `tests/fm-question-pretool-check-live-e2e.test.sh` | carried | 45dd50a5 |
