PR: #148

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| On Linux under a lingering user manager, the Herdr server and the remote job worker start in `firstmate.slice` through `systemd-run --user --scope` instead of the SSH session's scope | `bin/fm-linux-slice-lib.sh` (`fm_linux_slice_prefix`, fork-only), `bin/backends/herdr.sh` (`fm_backend_herdr_server_ensure`), `bin/fm-backend.sh` (sourced library list), `bin/fm-remote-job-lib.sh` (worker start), `docs/remote-secondmates.md`, `docs/scripts.md`, `docs/verification/runtime-backends.md`, `tests/fixtures.sh` (`fm_test_fake_linux_user_manager`), `tests/lib.sh`, `tests/fm-backend-herdr.test.sh`, `tests/fm-remote-job-orphan-reap.test.sh` | `bin/backends/herdr.sh`, `bin/fm-backend.sh`, `bin/fm-remote-job-lib.sh`, `docs/remote-secondmates.md`, `docs/scripts.md`, `tests/fm-backend-herdr.test.sh`, `tests/lib.sh` | conflicted | c8d8fdad |
