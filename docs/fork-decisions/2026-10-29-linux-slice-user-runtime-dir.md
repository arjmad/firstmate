PR: #149

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| When `XDG_RUNTIME_DIR` is unset, as under the remote entrypoint's emptied environment, the Linux slice decision uses the account's own `/run/user/<uid>` to reach the user bus and carries it to `systemd-run`, so the Herdr server and remote job worker still start in `firstmate.slice` | `bin/fm-linux-slice-lib.sh` (`fm_linux_slice_prefix`, fork-only), `tests/fm-backend-herdr.test.sh` (`test_linux_slice_prefix_finds_the_user_bus_without_xdg_runtime_dir`) | `tests/fm-backend-herdr.test.sh` | conflicted | c8d8fdad |
