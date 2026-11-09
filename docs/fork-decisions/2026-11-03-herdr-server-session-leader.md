PR: #163

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The Linux Herdr server starts as its own session leader inside `firstmate.slice`, so `herdr machine add --remote-session` accepts it as a saved machine | `bin/backends/herdr.sh` (`fm_backend_herdr_server_session_prefix`, `fm_backend_herdr_server_ensure`), `bin/fm-test-run.sh` (herdr e2e family entry), `docs/remote-secondmates.md`, `tests/fm-backend-herdr-detached-server-e2e.test.sh` (fork-only), `tests/fm-backend-herdr.test.sh` (`test_server_ensure_leads_its_own_session_inside_the_slice`) | `bin/backends/herdr.sh`, `bin/fm-test-run.sh`, `docs/remote-secondmates.md`, `tests/fm-backend-herdr.test.sh` | conflicted | c8d8fdad |
