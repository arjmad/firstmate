2026-10-27: Arjun picked "Session sets it at start" in a firstmate helm retro, after a steer failed because the helm forgot to prefix `FM_HOME`.
Decision: the Claude primary's SessionStart run wrapper appends `export FM_HOME='<home>'` to `CLAUDE_ENV_FILE`, so every later Bash command of a primary or secondmate helm session carries its own home.
The value is still explicit and per-home, and `bin/fm-send.sh`, `bin/fm-control.sh`, and `bin/fm-captain-hold.sh` keep their refusal to run without `FM_HOME`.
Task workers and gate agents stand down at the existing scope check before the write, so they keep the `FM_HOME` their launch sets.
No upstream proposal.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| An eligible Claude helm session exports its home to `CLAUDE_ENV_FILE` at session start | `bin/fm-sessionstart-run.sh` (`fm_export_home_to_claude_env`), `tests/fm-sessionstart-nudge.test.sh`, `docs/sessionstart-nudge.md` | same files | carried | 45dd50a5 |
