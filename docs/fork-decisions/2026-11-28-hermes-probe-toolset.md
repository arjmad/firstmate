2026-11-28: Arjun approved "Build it (Recommended)" after a Hermes toolset trim review measured a one-shot Cade probe at 38,926 input tokens with the full `cli` lane and 11,518 with `-t memory,no_mcp`.
Decision: firstmate's one-shot Hermes probes against a fleet agent's profile (`hermes -p <profile> -z`, `chat --oneshot`) pass `-t <toolsets>,no_mcp` by default, naming only the toolsets the probe needs, and widen by adding toolsets.
No firstmate code builds such a call, so the default is guidance in the Hermes harness reference, and `harness-adapters` gains the probe as a load trigger and a `probe` operation that loads only that reference.
The worker TUI launch in `bin/fm-spawn.sh` and the fleet repository's cron toolsets and `fleet-setup-token` are unchanged.
No upstream proposal: the probes and their fleet agents are this fleet's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| One-shot Hermes probes default to a narrow toolset plus `no_mcp` | `.agents/skills/harness-adapters/references/harness/hermes.md` (One-shot probes), `.agents/skills/harness-adapters/SKILL.md` (description, `probe` operation) | same files | carried | 38524c1a |
