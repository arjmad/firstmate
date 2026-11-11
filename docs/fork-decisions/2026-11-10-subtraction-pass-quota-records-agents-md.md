2026-11-10: A second firstmate batch of Arjun's 2026-11-10 ecosystem subtraction pass, under the same grill that lets firstmate ship each cut or fix that can be undone.
Decision: the pinned-account quota probe runs `claude -p /usage` from `/`, because run inside a firstmate home it fired that home's SessionStart hook and built a full digest for every probe, 79 times in 30 days.
Decision: close the fork-patch records whose every row reads `upstreamed` or `superseded`, and drop such rows from records that still carry live ones, so a sync re-checks only code the fork still carries; git history keeps each closed record.
Decision: narrow the #3, #5, #50, #76, and #94 rows to the files the fork still carries against upstream c8d8fdad, and spell the #110 owner values without an escaped pipe so a plain `|` split reads that row's cells.
Decision: `AGENTS.md` drops only the `/stow` and `/updatefirstmate` load restatements, section 10's repeat of section 7's `captain-hold-lifecycle` pointer, and the section 9 regression example the rule above it already states.
The load lines that guard a safety boundary stay, because Claude Code drops rarely used skills' descriptions first when its listing budget overflows (`harness-adapters` Claude reference), and section 13 and "Maintaining this file" stay because upstream carries both and their removal would conflict at every sync.
No upstream proposal: the quota probe and the records are this fork's own, and the `AGENTS.md` text is the fork's reduced copy.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The pinned-account `claude -p /usage` probe runs from `/` so no project SessionStart hook fires | `bin/fm-quota-snapshot.sh` (`claude_usage`), `tests/fm-quota-snapshot.test.sh` | none (fork-owned script) | carried | c8d8fdad |
| `AGENTS.md` drops the `/stow` and `/updatefirstmate` load restatements, section 10's repeated `captain-hold-lifecycle` pointer, and the section 9 regression example | `AGENTS.md` (sections 6, 9, 10, 12) | same file | carried | c8d8fdad |
