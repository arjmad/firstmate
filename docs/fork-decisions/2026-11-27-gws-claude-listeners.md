2026-11-27: Arjun ruled in the helm audit walk, on finding a5-90, "Build it (one shared workspace-mcp per mailbox on loopback)", and the fleet's listeners went live on Heimdall first.
Decision: an optional `claude_listeners <path>` in `config/google-workspace` names the fleet's listener table, and `bin/fm-google-workspace.sh claude-install` and `claude-config` then write each Claude Code `gws-<slug>` as an `http` server at its `claude` listener and the `--docs` opt-in file at its `claude-docs` listener, with no command, arguments, or environment.
The table stays the fleet's one source for ports, so firstmate holds no port of its own, and a home without the setting keeps its stdio servers unchanged.
The listeners carry the same `--disabled-tools` the stdio argv carried, from the same tool list, so every session keeps exactly its tools.
The whole table is checked before the first server is removed, so a bad row refuses the install rather than leave a store half moved.
No upstream proposal: the account layout and the listener table are this fleet's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A `claude_listeners` table points Claude Code's `gws-*` servers and the `--docs` file at shared loopback listeners by URL | `bin/fm-google-workspace.sh` (header, `usage`, `load_config`, `claude_listener_urls`, `cmd_claude_config`, `cmd_claude_install`), `tests/fm-google-workspace.test.sh`, `docs/configuration.md` (Google Workspace accounts, Docs workers), `docs/google-workspace-access.md` | same files | carried | 9ac0288e |
