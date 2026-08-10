# Native session-start nudge

AGENTS.md section 3 is the authoritative behavioral contract for session start.
The tracked native adapters inject one instruction and never run the digest, acquire the lock, perform bootstrap work, drain notifications, or arm supervision themselves.
Claude's `--claude` wrapper mode has one narrower state action: it records the validated payload session id as either the binding for an already-owned lock generation or an inert pid-bound proposal for the replacement owner that next acquires the lock.
The payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases.

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the single command every harness adapter invokes.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the hooks use one primary-detection owner.
The Shared Predicate section of [`turnend-guard.md`](turnend-guard.md#shared-predicate) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid, matching `bin/fm-lock.sh` and Pi's `lockOwnership()` ancestry depth.
Outside Claude mode, a live lock pid in that ancestry means session start already ran and the wrapper stays silent.
Claude's tracked hook invokes `--claude`, validates the payload session id, and uses the shared session-lock identity predicate before publishing `state/.claude-primary-session` for the existing numeric lock generation.
That direct rebinding handles a harness restart which retains the outer lock owner but moves later Stop hooks to a distinct Claude process lane.
If Claude does not already own the lock, the wrapper writes `state/.claude-primary-session.pending` with the session id, its resolved Claude harness pid, and creation time, then emits the unchanged session-start instruction.
The pending record has no ownership authority.
Only `bin/fm-lock.sh` can promote and remove a fresh proposal, and only after that exact resolved Claude pid becomes the verified numeric home-lock owner.
This covers a replacement outer owner before Stop moves to another process lane, while a competing session's pid-mismatched proposal cannot be promoted by the winner.
A nested Claude session with its own payload id cannot use the current binding, and a lock-refused session cannot publish one.
Every path exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.

## Harness transports

| Harness | Tracked transport | Current compatibility |
| --- | --- | --- |
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, excludes `compact`, and invokes the wrapper's `--claude` session-binding mode through `CLAUDE_PROJECT_DIR`. | Native stdout context injection and retained-lock session rebinding are supported. |
| Codex | `.codex/hooks.json` anchors to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is supported. |
| OpenCode | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. | The custom message reaches model context without racing an initial positional prompt. |
| Grok | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked secondmate primary, plus the tracked Claude `--claude` registration.
`tests/fm-claude-stop-autoarm.test.sh` exercises both restart bindings: a retained outer owner rebinding directly and a replacement owner promoting its pid-bound SessionStart proposal before a distinct post-restart Stop lane claims.
It also verifies tracked wrapper registration for Claude, Codex, OpenCode, Pi, and Grok.
`tests/fm-captain-translation-contract.test.sh` proves Ahoy's current marker rule, narrow legacy compatibility exclusions, genuine captain-message near misses, and the shared marker on supported user-role operational injections.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
