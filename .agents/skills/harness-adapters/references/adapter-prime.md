# prime-agent (EXPERIMENTAL VERIFIED CREW ADAPTER, 2026-08-08, v0.7.1)

Prime Agent is verified only as an explicitly selected crewmate or scout runtime.
It is never a dispatch default, and it is not verified as a firstmate primary or secondmate runtime.
The adoption decision is dated 2026-08-08.

| Fact | Value |
|---|---|
| Installed binary | npm-prefix package under `~/.local/prime-agent`; the adapter prefers `~/.local/prime-agent/node_modules/.bin/prime-agent` because the pilot wrapper at `~/.local/bin/prime-agent` forces one shared `TMPDIR`. |
| Version | PrimeIntellect-ai/prime-agent `v0.7.1`, pilot repository commit `a18809e00ea30638584d87b3afea7285a9d7296c`. |
| Launch | Interactive TUI with the initial encoded instructions as one positional argument after `--`; `--extension` loads the task event hook. |
| Config and auth | The captain's personal `~/.prime/agent` store remains authoritative; never set `PRIME_AGENT_CODING_AGENT_DIR`, create a fleet duplicate, print auth, or copy auth contents. |
| Task isolation | A short unique `/tmp/fmpa.XXXXXXXX` `TMPDIR` plus `PRIME_AGENT_SESSION_DIR=$FM_HOME/state/prime-agent/<task>/sessions`. |
| Telemetry | Always set `PRIME_AGENT_TELEMETRY=0` and `DO_NOT_TRACK=1`; the installed v0.7.1 build was also source-grepped on 2026-08-08 and contains no telemetry sender. |
| Detection marker | Firstmate launches with `PRIME_AGENT_FIRSTMATE=1`; command ancestry also recognizes `prime-agent`. |
| Busy-pane signature | `^[[:space:]]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Waiting|Executing)([[:space:]]+·|$)`. |
| Idle state | The pane has no positive idle-only footer; `prime-agent list --json` under the task environment is authoritative. |
| Composer | Bordered editor with the ordinary `> ` prompt prefix; the shared composer classifier recognizes bordered `>` as empty but never treats a bare shell `>` as an agent composer. |
| Steer | `prime-agent send <active-session-id> <message> --json` under the task environment; plain `send` reports `deliveryMode: "steer"`. |
| Broken flag | v0.7.1 advertises `send --steer` but rejects it as unknown; never use `--steer`. |
| Interrupt | Send one Escape to the TUI pane; steering does not abort an in-flight Python call. |
| Detach | Send Ctrl-D to the TUI pane; the daemon and worker may continue. |
| Reattach | `prime-agent attach <active-session-id>` under the same task environment. |
| Cleanup | Run task-scoped `stop <active-session-id>`, then `shutdown --force` against that task's unique `TMPDIR` only. |
| Event hook | `agent_end` appends the ready notification because one request may span multiple `turn_end` events; `session_shutdown` appends a clean lifecycle notification. |
| Model flag | `--model <model>`. |
| Effort flag | `--thinking <level>`. |
| Skill invocation | No separate verified form; use natural language. |
| Trust dialog | No repository trust dialog was observed in the 2026-08-08 pilot. |

## Effort mapping

Firstmate maps its shared effort values directly to Prime Agent v0.7.1 thinking levels.

| Firstmate effort | Prime Agent thinking |
|---|---|
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `xhigh` | `xhigh` |
| `max` | `max` |

Prime Agent also accepts `off` and `minimal`, but those values are outside firstmate's shared effort vocabulary and are not emitted by `fm-spawn`.

## Authoritative state

Run `bin/fm-prime-agent.sh state state/<task>.meta` rather than inferring idle from pane text.
The task-scoped command matches the recorded `activeSessionId` and reads `activity`, streaming, tool, bash, compaction, child, and unfinished-action fields from `list --json`.
A busy spinner is useful positive evidence while rendered, but spinner absence is not positive idle evidence.

## Control boundaries

Plain `send` is a steer for the next model step, not an interrupt for a running IPython or shell call.
Use pane Escape when the current turn must stop.
Use Ctrl-D only to detach the client.
Final cleanup must target the task session before shutting down the daemon behind that task's unique short `TMPDIR`; never run a shared Prime Agent shutdown.

## Persistent execution caveat

The pilot proved that the IPython namespace and active execution survive detach and reattach.
Prime Agent's Python worker has user permissions and is not a sandbox, so the ordinary isolated project-copy requirement remains mandatory.
Continual-harness refinements are experimental and must remain inspectable; do not treat auto-refinement as trusted policy.
