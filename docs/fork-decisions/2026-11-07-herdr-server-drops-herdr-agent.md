PR: #201

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A started Herdr server, and every Herdr lab call, drops the wrapper's `HERDR_AGENT` hint, so panes the server spawns are not all detected as that agent and the same-identity reclaim after a session restart works again | `bin/backends/herdr.sh` (`fm_backend_herdr_server_ensure`), `bin/fm-herdr-lab.sh` (every `herdr` call), `docs/herdr-backend.md`, `docs/verification/runtime-backends.md`, `tests/fm-backend-herdr-presentation-e2e.test.sh`, `tests/fm-backend-herdr-respawn-idem-e2e.test.sh`, `tests/fm-backend-herdr-smoke.test.sh`, `tests/fm-backend-herdr.test.sh`, `tests/fm-herdr-lab.test.sh` (`test_provision_drops_inherited_agent_detection_hint`) | `bin/backends/herdr.sh`, `bin/fm-herdr-lab.sh` (upstream's `env -u HERDR_SOCKET_PATH ...` wrapper) | conflicted | c8d8fdad |
