2026-10-27: Arjun ruled on the Claude Code board's recommendation 2, to turn the Artifact tool and claude.ai connectors off for workers: "turn both off for workers only".
Decision: every Claude ship and scout launches with `"enableArtifact": false` and `"disableClaudeAiConnectors": true` in its inline `--settings` JSON, while the helm, the desktop app, and secondmates keep both.
Fleet guidance already forbids a worker from publishing an artifact or opening a Claude Doc without his word, so the tool text was paid on every worker turn for tools the worker may not use.
Off in `--settings` wins over user and project settings for both keys in the Claude Code 2.1.310 settings schema, and claude.ai connectors leave every local MCP server (`gws-*`, gbrain, Exa, Firecrawl, Higgsfield) connected.
Live check on 2.1.310, a throwaway interactive session in a firstmate worktree: the first turn's input fell from 68,279 to 54,131 tokens, and the session listed no `Artifact`, `ArtifactComments`, `ArtifactData`, or `mcp__claude_ai_*` tool, where the same launch without the keys listed all of them; `DesignSync` stays, since neither key governs it.
No upstream proposal.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A Claude ship or scout launches with the Artifact tool and claude.ai connectors off in its inline `--settings` JSON | `bin/fm-spawn.sh` (`launch_template` claude comment, inline `claude_settings`), `tests/fm-spawn-dispatch-profile.test.sh`, `tests/fm-backend-orca.test.sh`, `.agents/skills/harness-adapters/references/harness/claude.md` | same files | carried | 45dd50a5 |
