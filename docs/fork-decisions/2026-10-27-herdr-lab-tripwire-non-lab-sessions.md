PR: #135

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The Herdr lab's fleet-state tripwire records every running non-lab session (`default`, or a named live fleet such as `fm-remote`) rather than only one running `default`, and refuses when that set is empty or unreadable; upstream's `FM_HERDR_LAB_FLEET_SESSION` override, which names one fleet session, sits beside it | `bin/fm-herdr-lab.sh` (`fm_herdr_lab_fleet_state`, header), `bin/fm-brief.sh` (`--herdr-lab` contract item 6), `tests/fm-herdr-lab.test.sh` (`test_tripwire_follows_a_non_default_live_fleet`, `test_unreadable_session_list_refuses_provision`), `tests/fm-brief.test.sh` | `bin/fm-herdr-lab.sh` (`FM_HERDR_LAB_FLEET_SESSION`), `bin/fm-brief.sh`, `docs/herdr-backend.md`, `tests/fm-herdr-lab.test.sh`, `tests/fm-brief.test.sh` | conflicted | c8d8fdad |
