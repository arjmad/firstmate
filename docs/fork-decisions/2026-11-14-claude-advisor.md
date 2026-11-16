2026-11-14: Arjun, in a worker pane, approved adding Fable as the advisor for the Opus 5.5 seats with "Yes let's do it", after the recommendation noted that each advisor call adds Fable usage.
Decision: a crew-dispatch profile may declare `advisor`, and a Claude ship or scout launched from it starts with `--advisor <model>`, which sets the advisor for that one session without writing Claude settings; this fleet's `claude-opus-5-5` profiles declare `"advisor": "fable"`.
The field is valid only on harness `claude` with an explicit model that is not a Fable model, because a Fable main accepts only a Fable advisor and the pairing would double Fable use; an invalid profile is a configuration error and `fm-spawn.sh` refuses the launch rather than dropping the field.
The task record keeps it as `advisor=`, and a relaunch keeps it only while the harness and model stay the same.
Secondmate launches and the merge-gate code review take no advisor; Arjun did not name them.
Claude Code 2.1.323 on Fafnir answered `claude -p --model claude-opus-5-5 --advisor fable "Reply with just: ok"` with `ok`.
No upstream proposal: the advisor pairing is this fleet's spend choice.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| A crew-dispatch profile's advisor launches a Claude ship or scout with --advisor and records advisor= | `bin/fm-spawn.sh` (header, `--advisor` parsing, batch `shared_args`, advisor validation, dispatch-record match, t3code refusal, `launch_template` claude `__CLAUDEADVISOR__`, task record, `preserve_relaunch_meta`), `bin/fm-harness.sh` (`validate-advisor`), `tests/fm-spawn-dispatch-profile.test.sh` | same files | conflicted | 427056c4 |
| A crew-dispatch profile's advisor launches a Claude ship or scout with --advisor and records advisor= | `bin/fm-control.sh` (relaunch `--advisor`, `resolve_relaunch_profile`, journal), `tests/fm-control-relaunch.test.sh` | same files | carried | 427056c4 |
| A crew-dispatch profile's advisor launches a Claude ship or scout with --advisor and records advisor= | `bin/fm-dispatch-resolve.sh` (rules validation, profile line, task record), `bin/fm-bootstrap.sh` (`crew_dispatch_validate`), `tests/fm-dispatch-resolve.test.sh`, `tests/fm-bootstrap.test.sh`, `docs/configuration.md`, `docs/agent-control.md`, `.agents/skills/harness-adapters/references/common/dispatch.md`, `.agents/skills/harness-adapters/references/harness/claude.md` | same files | carried | 427056c4 |
