PR: #5

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Recover a Herdr pane whose agent exited but left a stale registration; upstream now has the stale-agent classification, and the fork carries only the state-capable `ps` probe, the `agent get` read-failure guard, and the husk-replacement recheck | `bin/backends/herdr.sh` (`fm_backend_herdr_ps_bin`, `fm_backend_herdr_ps_state_capable`, `fm_backend_herdr_pane_agent_state`, husk replacement), `docs/herdr-backend.md`, `tests/fm-backend-herdr.test.sh` | `bin/backends/herdr.sh`, which upstream #8317 changed after c8d8fdad, so the next sync re-checks this row by hand | carried | c8d8fdad |
