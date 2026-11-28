2026-11-28: Arjun ruled at the helm grill selector on a ship PR that waits for his return only because its body lacks a `Class:` line, ticking "Allow it (Recommended)".
Decision: while he is away, the away branch actor may add a missing `Class: <word>` line to a ship PR body, and nothing else on a PR; such a PR then merges on green as usual.
It supersedes the away line of the [effort-class split](2026-11-27-effort-class-split.md), under which adding that line was main's, so the PR held for the return.
Decision: `bin/fm-pr-merge.sh --add-class <word>` is the one write path, so the one-line limit is enforced where the merge gates run: away-only, GitHub-only, a known word, a brief that asks for the line, and a body with no Class line that is unchanged since the live verify; it appends that line at most once a run and reads the body back, waits a bounded settle time for a workflow the edit starts, and every live gate then reads the PR again before the merge runs as before.
A wrong Class word, or any other PR body, title, label, or comment change, still waits for him; attended merges and which PRs need the line are unchanged.
No upstream proposal: the Class line and the away posture rule are this fork's.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The away actor's one PR write: `--add-class` adds a missing Class line under the away record's lock, then the merge runs on | `bin/fm-pr-merge.sh` (header, usage, `--add-class` parse, `require_current_away_authority`, `require_pr_class`, `github_add_class_line`), `tests/fm-pr-merge.test.sh` (fake `gh pr edit` and body read, `test_pr_class_*add_class*`) | `bin/fm-pr-merge.sh`, `tests/fm-pr-merge.test.sh` | carried | 9ac0288e |
| The away branch instruction and the docs | `bin/fm-branch-prompt.sh` (away merge line), `docs/pi-supervision-branch.md` (authority relocation table), `docs/scripts.md` | `bin/fm-branch-prompt.sh`, `docs/pi-supervision-branch.md`, `docs/scripts.md` | carried | 9ac0288e |
