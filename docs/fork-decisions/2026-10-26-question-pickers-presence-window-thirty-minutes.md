PR: #115

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The question picker's presence window is thirty minutes, not ten (`FM_QUESTION_PRESENT_SECONDS` default 1800), Arjun's pick of retro 2026-10-26 candidate 12 in the helm ("30 minutes"); it widens the #85 window | `bin/fm-question-lib.sh` (`fm_question_present_window`, header), `tests/fm-question-pretool-check.test.sh` | `bin/fm-question-pretool-check.sh` (deny age rounds up), `docs/supervision-protocols/claude.md` | carried | 45dd50a5 |
