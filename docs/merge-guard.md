# merge-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the merge-guard PreToolUse seatbelt.
`bin/fm-merge-command-policy.mjs` is the single decision owner.
`bin/fm-merge-pretool-check.sh` is the stable harness transport, primary-home scope, and output renderer.
The tracked harness adapters forward command text without classifying it.

It is a member of the family of primary-session guards that share the same cross-harness hook machinery: the watcher-arm seatbelt (`docs/arm-pretool-check.md`), the cd-guard (`docs/cd-guard.md`), and the turn-end supervision guard (`docs/turnend-guard.md`).

## Purpose and boundary

`bin/fm-pr-merge.sh` owns the guards a PR landing must pass: the pull request is open and mergeable, every check is green at the exact current head, required checks have reported, merge authority holds, and the merge is bound to the verified head.
A raw `gh pr merge` typed into the primary shell skips every one of them, and it has actually happened: a primary session merged a PR with a raw `gh-axi pr merge`.
The seatbelt denies that command shape before it runs and names the sanctioned path instead.

This guard is not a general sandbox.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes, the same as the cd-guard: an accidental raw merge, not a deliberately obfuscated bypass.

## Scope: primary homes only

The guard fires only where `fm_primary_root_matches` in `bin/fm-primary-scope-lib.sh` accepts the checkout, the same primary-home predicate the turn-end guard uses (`docs/turnend-guard.md`, "Primary scope").
That is a plain firstmate checkout, or a home carrying a valid `.fm-secondmate-home` marker whether it is a plain clone or a treehouse-leased linked worktree, because a secondmate's own session is a supervisor too.
It is a silent no-op (exit 0, no output) in a crewmate or scout linked worktree and outside any firstmate checkout.
Workers keep calling `gh` freely, and `bin/fm-pr-merge.sh` keeps merging, because the guard sees only the tool command and never the children of a script that command runs.
Any failure to confirm a primary home is treated as inert, never as a block.

## Block vs allow

The guard **blocks** a command whose executed command word is `gh` or `gh-axi` (by basename, so any install path) when it is:

- `pr merge`, with or without a `-R`/`--repo` value before or after `pr`, including `--auto`.
- `api` with a REST endpoint ending in `pulls/<n>/merge` and a write method: an explicit method other than `GET` or `HEAD`, or no method but a body flag (`-f`, `-F`, `--field`, `--raw-field`, `--input`), which makes `gh api` default to `POST`.
- `api graphql` with any argument naming `mergePullRequest`, `enablePullRequestAutoMerge`, or `enqueuePullRequest`.

Unlike a directory change, a merge lands wherever it runs, so the guard inspects every command-list position, including pipeline stages, backgrounded commands, subshell and brace groups, command substitutions, `env -S` payloads, literal `sh`/`bash`/`zsh -c` payloads, and literal `eval` payloads.
Leading assignments and the `env`, `command`, `exec`, `sudo`, `nohup`, `timeout`, and `gtimeout` wrappers are skipped to find the command word.

The guard **allows** everything else, including:

- The sanctioned paths: `bin/fm-pr-merge.sh <task> <pr-url>` and `~/nix/bin/brain-managed-refresh arjun --merge-pr <n>`.
- Reads such as `gh pr view`, `gh pr list --search merge`, `gh pr status`, and a `GET` of the merge endpoint, which only reports whether the PR merged.
- `gh pr merge --help` and `gh pr merge --disable-auto`, which merge nothing.
- The text `gh pr merge` as data: quoted, in a comment, or as an argument to `echo`, `grep`, or `printf`.
- `git merge` and every other command.

### Accepted non-goals

- A merge behind a command runner the classifier does not unwrap (`xargs`, `time`, `find -exec`, `watch`), a `gh` alias, a GraphQL query read from `--input <file>`, or a command word built by expansion is not blocked.
- Malformed or untokenizable syntax fails open (allow), because a false block on a legitimate command is worse than the missed exotic bypass.
- Merges outside the primary shell tool, such as the forge web UI, are outside this guard.

## Stable reason code

Every deny carries one stable code in square brackets before its one-line prose reason.

| Code | Meaning |
| --- | --- |
| `raw-pr-merge` | The command merges a PR directly through the GitHub CLI instead of `bin/fm-pr-merge.sh`. |

The reason names `bin/fm-pr-merge.sh <task> <pr-url>`, and `~/nix/bin/brain-managed-refresh arjun --merge-pr <n>` for a brain PR.

## Transport, fail-open behavior, and output

The transport accepts the same entry shapes and renders the same outputs as `bin/fm-cd-pretool-check.sh`, so `docs/cd-guard.md` "Transport and fail-open behavior" and "Output contract" apply unchanged with the code `raw-pr-merge`.
It has no Claude maintained-working-directory shortcut: that relaxation is specific to directory changes.

Processing order is cheapest-first: a strict-superset prefilter, then the primary-home scope, then the Node policy owner.
The prefilter removes ordinary quotes, backslashes, carriage returns, and newlines, then fast-allows any command carrying neither `merge`, `Merge`, nor `enqueuePullRequest` and no quoting-decoder marker (`$'` or `$"`).
That substring set is coupled to the policy's denied shapes, and the decoder markers are coupled to `bin/fm-arm-command-policy.mjs` exactly as the cd-guard's are.

## Shared classifier ownership

`bin/fm-merge-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification, and adds only the merge-specific decision on top.

## Harness wiring

| Harness | Entry | Adapter behavior on deny |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse `Bash` hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook anchored on `pwd -P`, the same shape as the cd-guard entry | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-merge-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-primary-merge-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler, after the cd-guard | Returns `{block: true, reason}`. |
| omp | `.omp/extensions/fm-primary-turnend-guard.ts` `tool_call` handler, after the cd-guard | Returns `{block: true, reason}`. |
| Cursor | `.cursor/hooks.json` `preToolUse` hook matching `Shell`, forwarding stdin with `--cursor` | Prints Cursor's `{"permission":"deny",...}` object and exits 0. |

Each harness runs the merge guard alongside the watcher-arm seatbelt and the cd-guard; the checks are independent, and any deny blocks the command.

## Automated validation

`tests/fm-merge-pretool-check.test.sh` owns the acceptance matrix, run through Codex, Claude, Grok, Cursor, OpenCode, and Pi entry forms.
It also proves the one-line refusal text, the primary-home scope (both secondmate home shapes fire, crewmate worktrees and non-firstmate directories stay inert), the end-to-end regression (the raw merge reaches a fake `gh`, the guard denies that exact command, and the sanctioned script's own merge still reaches `gh`), fail-open transport, the prefilter fast path, and the policy CLI.
Its registration tests run each tracked Claude, Codex, Cursor, and Grok hook command, the OpenCode plugin, and the Pi and omp extensions' `tool_call` handlers against a primary-shaped fixture.

Run:

```sh
node --check bin/fm-merge-command-policy.mjs
bin/fm-lint.sh bin/fm-merge-pretool-check.sh tests/fm-merge-pretool-check.test.sh
tests/fm-merge-pretool-check.test.sh
```

## Live validation record, 2026-10-11

Each harness ran in a scratch primary-shaped checkout: a plain git repo with `AGENTS.md`, `bin/` holding the real transport, policy, shared classifier, and scope and host libraries plus no-op stand-ins for the other hooks, and only the merge-guard registration from the tracked hook config.
A fake `gh` touched a `VIEWED` or `MERGED` sentinel and never reached GitHub.
Each harness was told to run, as separate tool calls, `<fake>/gh pr view 148` (must run) and `<fake>/gh pr merge 148 --squash` (must be denied).

- **Claude Code 2.1.296** - blocked. Claude reported the merge "blocked before execution by a PreToolUse hook (the `fm-merge-pretool-check.sh` guard)" with the `[raw-pr-merge]` reason; only the `VIEWED` sentinel existed.
- **Pi 1.1.0** - blocked. The `[raw-pr-merge]` reason reached the model and only the `VIEWED` sentinel existed; that differential in one session can only come from the guard.
- **codex-cli 0.162.1** - blocked. Codex logged `error=Command blocked by PreToolUse hook: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[raw-pr-merge] ..."}` and `hook: PreToolUse Blocked`; only the `VIEWED` sentinel existed.
- **OpenCode, omp, Grok, and Cursor** were not installed on the validating host, so they have no live run; their tracked registrations are exercised by the registration tests above.

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
```
