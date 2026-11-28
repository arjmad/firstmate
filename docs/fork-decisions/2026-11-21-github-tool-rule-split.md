2026-11-21: Arjun picked skills item T04 at his 2026-11-21 skills review: the helm ran plain `gh` 1,309 times against `gh-axi` 867 in 30 days, mostly for scripted reads.
Decision: on GitHub, `gh-axi` stays the tool to create, review and comment on PRs and for views a person reads, and plain `gh` with `--json`/`--jq` is the tool for scripted reads.
Merge wording is unchanged: raw `gh pr merge` stays hook-blocked and `bin/fm-pr-merge.sh` stays the merge path.
No upstream proposal: the split records this fleet's own usage.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The GitHub tool rule splits PR actions and human views (`gh-axi`) from scripted reads (plain `gh --json/--jq`), and the ship brief wait line names `gh-axi pr checks --watch --fail-fast` | `AGENTS.md` (section 1 tool rule), `bin/fm-brief.sh` (`FORGE_RULE_LINE`, scout Rule 3, Waiting), `docs/configuration.md` (toolchain list), `tests/fm-brief.test.sh`, `tests/fm-dod-lib.test.sh` (comment) | same files | carried | 9ac0288e |
