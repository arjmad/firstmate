2026-11-11: Arjun ruled that the Home Assistant MCP server is for his sessions and the helm, not the workers (2026-10-25), and that Monarch stays on the main account, away from workers (2026-10-30); the fleet repository's `dotfiles/claude/README.md` records both rulings.
Until now only the worker's Claude account held that rule, and since the two-stage account drain moves workers between accounts by itself, a worker on the main account loaded both servers: a scout on 2026-11-11 held 72 of their tools, among them a Home Assistant turn-on and a Monarch delete.
Decision: every Claude ship and scout launches with the servers `config/worker-denied-mcp-servers` lists in `"deniedMcpServers"` in its inline `--settings` JSON, on either account, which is the fix the fleet repository's `docs/home-assistant.md` names.
The fleet repository owns the list, as `fleet.claude.mainAccountOnlyMcpServers`; the home file holds it until the fleet repository deploys a rendered copy the home file can point at.
A present but unreadable or malformed list refuses a Claude ship or scout spawn, so a home that declares the rule never launches a worker without it.
The file is inherited into secondmate homes, because their own crewmates run on the same accounts.
Live check on Claude Code 2.1.319: a `claude -p` session given a stdio server through `--mcp-config` and `--settings '{"deniedMcpServers":[{"serverName":"<name>"}]}'` printed "MCP server blocked by enterprise policy: <name>" and never started it, while the same launch with `--settings '{}'` started it.
No upstream proposal: the list is this fleet's account layout.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A Claude ship or scout launches with the home's denied MCP servers in its inline `--settings` JSON | `bin/fm-spawn.sh` (header, `launch_template` claude comment, inline `claude_settings`, worker MCP gap warning), `tests/fm-spawn-dispatch-profile.test.sh` | same files | carried | f94eaf7d |
| A Claude ship or scout launches with the home's denied MCP servers in its inline `--settings` JSON | `bin/fm-exclude-tools-lib.sh` (`fm_config_name_list`, `fm_worker_denied_mcp_servers_check`), `bin/fm-control.sh` (relaunch precheck) | same files | carried | f94eaf7d |
| A Claude ship or scout launches with the home's denied MCP servers in its inline `--settings` JSON | `bin/fm-config-inherit-lib.sh` (`FM_INHERITABLE_CONFIG`), `docs/configuration.md`, `docs/agent-control.md`, `.agents/skills/operational-home-layout/SKILL.md`, `.agents/skills/harness-adapters/references/harness/claude.md` | same files | carried | f94eaf7d |
