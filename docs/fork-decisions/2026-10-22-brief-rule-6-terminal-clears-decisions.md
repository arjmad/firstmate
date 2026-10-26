PR: #97

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Ship and scout brief rule 6 says a `done:` or `failed:` declaration clears every open decision, matching the terminal fold; the secondmate text keeps resolved-only | `bin/fm-brief.sh` (ship and scout rule 6), `tests/fm-brief.test.sh` (`test_decision_rule_matches_terminal_fold`) | same lines, `tests/fm-brief.test.sh` (custom-pause rule-6 assertion) | carried | 45dd50a5 |
