## prime-agent (EXPERIMENTAL VERIFIED CREW ADAPTER, 2026-08-08, Prime Agent v0.7.1)

Prime Agent is verified only as an explicitly selected CREWMATE or SCOUT runtime.
It is never a dispatch default, and it is not verified as a firstmate primary or secondmate runtime.
`bin/fm-spawn.sh` refuses `--secondmate` on it, and it has no supervision protocol under `docs/supervision-protocols/`.
The adoption decision is dated 2026-08-08.

| Fact | Value |
|---|---|
| Binary | npm-prefix package under `~/.local/prime-agent`; the adapter prefers `~/.local/prime-agent/node_modules/.bin/prime-agent` because the pilot wrapper at `~/.local/bin/prime-agent` forces one shared `TMPDIR`. `PRIME_AGENT_REAL_BIN` overrides it for tests and operators. |
| Launch | Interactive TUI with the encoded instructions as one positional argument after `--`; `--extension` loads the per-task event hook. Every invocation goes through `bin/fm-prime-agent.sh`, the single owner of the task-scoped environment. |
| Config and auth | The captain's personal `~/.prime/agent` store stays authoritative; never set `PRIME_AGENT_CODING_AGENT_DIR`, create a fleet duplicate, print auth, or copy auth contents. |
| Task isolation | A short unique `/tmp/fmpa.XXXXXXXX` `TMPDIR` plus `PRIME_AGENT_SESSION_DIR=<home>/state/prime-agent/<task>/sessions`, both recorded in `state/<id>.meta` as `prime_tmp=` and `prime_session_dir=`. The short root is mandatory: the daemon and worker talk over Unix sockets below `TMPDIR`, and a long home or worktree path fails with `EINVAL`. |
| Telemetry | Always `PRIME_AGENT_TELEMETRY=0` and `DO_NOT_TRACK=1`; the installed v0.7.1 build was also source-grepped on 2026-08-08 and contains no telemetry sender. |
| Environment marker | `PRIME_AGENT_FIRSTMATE=1`, set by the adapter on its own task processes and checked FIRST in `bin/fm-harness.sh` so a foreign primary marker inherited through the launch cannot outrank it. Command ancestry also recognizes `prime-agent`, including as a bare `node` interpreter's script path. |
| Busy state | Its own `list --json` verdict for the recorded session, folded by `bin/fm-prime-agent.sh state` and read on demand by `bin/fm-busy-lib.sh` as `prime-agent-list`. There is no writer, so nothing is armed and no busy record is ever seeded. |
| Busy-pane signature | `^[[:space:]]*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][[:space:]]+(Waiting\|Executing)([[:space:]]+·\|$)`, used only for the rendered delivery guard. |
| Idle state | The pane has NO positive idle-only footer, so spinner absence proves nothing. Read state through the adapter, never from pane text. |
| Composer | Bordered editor with the ordinary `> ` prompt prefix; the shared classifier reads a bordered `>` as empty and a bare shell `>` as never an agent composer. |
| Steer | `prime-agent send <active-session-id> <message> --json` under the task environment; plain `send` reports `deliveryMode: "steer"`. `fm-send` routes a prime-agent target through the adapter instead of typing at the composer, and refuses unless the daemon reports a queued or delivered steer. |
| Broken flag | v0.7.1 advertises `send --steer` but rejects it as unknown; never use `--steer`. |
| Interrupt | Single Escape to the TUI pane, through `bin/fm-control.sh <id> interrupt`. Steering does NOT abort an in-flight Python or shell call. |
| Exit command | None verified. Ctrl-D DETACHES the client and leaves the daemon and worker running, so `fm-control` refuses `exit` and `relaunch` for this adapter rather than reporting a stop it cannot prove; `fm-spawn --relaunch` refuses for the same reason. Tear the task down to end it. |
| Reattach | `prime-agent attach <active-session-id>` under the same task environment. |
| Cleanup | Task-scoped `stop <active-session-id>`, then `shutdown --force` against that task's unique `TMPDIR` only. `bin/fm-teardown.sh` runs it before the isolated copy is returned, and preserves the task if it fails. Never run a shared Prime Agent shutdown. |
| Event hook | `agent_end` appends the ready NOTIFICATION because one request may span many `turn_end` events; `session_shutdown` appends a clean lifecycle notification. Neither is current-state truth. |
| Model flag | `--model <model>`. |
| Effort flag | `--thinking <level>`. |
| Skill invocation | No separate verified form; use natural language. |
| Trust dialog | None observed in the 2026-08-08 pilot. |

## Effort mapping

Firstmate maps its shared effort values directly onto Prime Agent v0.7.1 thinking levels.

| Firstmate effort | Prime Agent thinking |
|---|---|
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `xhigh` | `xhigh` |
| `max` | `max` |

Prime Agent also accepts `off` and `minimal`, but those sit below firstmate's shared effort vocabulary and are never emitted by `fm-spawn`.

## Authoritative state

Run `bin/fm-prime-agent.sh state state/<task>.meta`, or read the ordinary classified state, rather than inferring idle from pane text.
The task-scoped command matches the recorded `activeSessionId` and folds `activity`, streaming, tool, bash, compaction, child, and unfinished-action fields from `list --json`.
A rendered busy spinner is useful positive evidence while it is on screen, but its absence is not positive idle evidence: Prime Agent's daemon keeps working after its TUI detaches.

## Control boundaries

Plain `send` is a steer for the next model step, not an interrupt for a running IPython or shell call.
Use `fm-control.sh <id> interrupt` when the current turn must stop.
Ctrl-D detaches a client only, which is why this adapter has no exit or relaunch verb.
Final cleanup must target the task session before shutting down the daemon behind that task's own short `TMPDIR`.

## Persistent execution caveat

The pilot proved that the IPython namespace and active execution survive detach and reattach.
Prime Agent's Python worker runs with user permissions and is not a sandbox, so the ordinary isolated project-copy requirement remains mandatory.
Continual-harness refinements are experimental and must stay inspectable; never treat auto-refinement as trusted policy.
