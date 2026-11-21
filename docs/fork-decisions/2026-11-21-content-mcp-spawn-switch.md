2026-11-21: Arjun ruled at the helm, on the skills and tools grill, "Higgsfield only when needed".
Decision: Claude Code keeps the Higgsfield MCP server out of its user scope, and a content session loads it through `--mcp-config` with the fleet-rendered `~/.config/fleet/claude/content.mcp.json`; for firstmate workers that is the `fm-spawn.sh --content` switch.
The switch never adds `--strict-mcp-config`, so a content worker keeps its other MCP servers, and its task record carries `content=on` so a relaunch keeps it.
A content launch refuses rather than starts when a denial would hide a content server or its `authenticate` or `complete_authentication` sign-in tool, because `--disallowedTools` cannot reopen one tool inside a matching pattern.
No upstream proposal: the content server set is this fleet's account layout.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A `--content` Claude ship or scout loads the content MCP config through `--mcp-config` and records content=on | `bin/fm-exclude-tools-lib.sh` (header, `fm_content_mcp_config_file`, `fm_content_mcp_check`), `bin/fm-spawn.sh` (header, `--content` parsing and refusals, batch `shared_args`, relaunch restore, content check, `launch_template` claude `__CLAUDECONTENTMCP__`, task record, Orca recovery record, `preserve_relaunch_meta`, spawned line), `bin/fm-control.sh` (header, relaunch precheck), `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-control-relaunch.test.sh`, `tests/lib.sh`, `tests/fixtures/content.mcp.json`, `docs/configuration.md` (Content workers), `docs/agent-control.md`, `.agents/skills/harness-adapters/references/harness/claude.md` | same files | carried | 427056c4 |
