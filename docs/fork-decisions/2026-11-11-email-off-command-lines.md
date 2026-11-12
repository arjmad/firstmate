2026-11-11: Arjun asked at the helm why he had to allow a worker to continue twice; the worker's Bash commands held an email address, and Claude Code stopped each one for confirmation even in bypass mode.
Decision: every generated ship and scout brief carries a standing rule to keep email addresses out of command lines (read them from a file or a script, never echo them), because the harness stops such a command for a confirmation nobody can answer.
No hook approves the prompt and no permission setting changes.
No upstream proposal yet: the stall comes from this fleet's harness behavior.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| Ship and scout briefs carry the email-address rule | `bin/fm-brief.sh` (`SHARED_NO_CD_RULE`), `tests/fm-brief.test.sh` | same file | carried | c8d8fdad |
