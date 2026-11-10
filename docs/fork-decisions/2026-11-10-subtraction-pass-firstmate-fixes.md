2026-11-10: Arjun asked for an ecosystem subtraction pass, and a grill that day let firstmate ship each cut or fix that can be undone; this record covers its firstmate batch.
Decision: fix `fm-inbox.sh reply` so a help flag prints its usage and records nothing, because a recorded reply cannot be replaced.
Decision: remove the one-time retirement of the dropped default release, because no home holds release leftovers and no backlog row keeps a `; releases` default; this supersedes the retirement row of the [drop-default-release record](2026-11-01-drop-default-release.md), and a re-hold still keeps an old row's default as its recommendation.
Decision: the secondmate-restart test's EXIT trap calls the shared test cleanup, so the read-only `*.git-hooks` dirs its secondmate homes hold are removed with the rest of its temp root.
No upstream proposal: the inbox and test fixes are small enough to carry until a sync, and the retirement was this fork's own code.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| `reply` prints its usage for `-h` or `--help` in the note-id or body position instead of recording the flag as the reply | `bin/fm-inbox.sh` (`cmd_reply`), `tests/fm-inbox.test.sh` (reply help case) | `bin/fm-inbox.sh` (`cmd_reply`), `tests/fm-inbox.test.sh` | carried | c8d8fdad |
| The secondmate-restart test's EXIT trap runs `fm_test_cleanup` instead of a plain `rm -rf` | `tests/fm-secondmate-restart.test.sh` (EXIT trap) | `tests/fm-secondmate-restart.test.sh` | carried | c8d8fdad |
| `AGENTS.md` drops six lines that only repeated a skill description's load trigger | `AGENTS.md` (sections 2, 3, 6, 7, 8) | `AGENTS.md` | carried | c8d8fdad |
