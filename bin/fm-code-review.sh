#!/usr/bin/env bash
# Independent code review on the merge path (fork patch, docs/fork-decisions.md
# 2026-10-17). This file is the single owner of which pull requests need that
# review and of the record that proves one ran; bin/fm-pr-merge.sh refuses a
# GitHub merge its status calls unreviewed, and bin/fm-dod-lib.sh tells a ship
# worker to run the review before its ready report.
#
# When the repository's main branch keeps a risk-tiers.toml at its root
# (docs/fork-decisions.md 2026-10-19), that tier table alone decides, through
# the fleet's classifier `risk-tier --root <clone> --head <pull request head>`
# (the fleet's docs/risk-tiers.md owns its rules): a tinker pull request is
# exempt, and any other tier is code-changing. The classifier is
# $FM_RISK_TIER, by default ${FLEET_NIX:-$HOME/nix}/bin/risk-tier, run on a
# throwaway blob-less clone of main and the pull request's head; a missing
# classifier, a clone or fetch that fails, or a classifier that refuses the
# table leaves the review state unreadable, so the merge refuses.
#
# Without a table, a changed path is exempt when it lies under docs/records/,
# docs/receipts/, data/, or seed/, or names a Markdown file (*.md), and a pull
# request is code-changing when any changed path is not exempt, so a receipts,
# records, or prose-only pull request merges on green alone and everything
# else carries a review first.
#
# Without a table a rename counts both its names, and GitHub lists at most
# 3000 changed files, so a pull request at that cap counts as code-changing,
# since the files it leaves unlisted cannot be classified.
#
# The review is Claude Code's built-in /code-review skill at its medium level,
# run headless by `review` on the home's pinned model with the PR number and
# firstmate's merge-gate focus (fork patch,
# docs/fork-decisions/2026-11-10-code-review-focus.md). The skill runs in a
# forked context that sees only its own arguments, so the focus rides there:
# it skips the finding kinds authors declined (cleanup, altitude, test quality,
# hardening for states nothing produces, intended behavior, pre-existing code)
# and keeps full recall on correctness bugs and wrong instructions. `review`
# then posts each finding itself (fork patch,
# docs/fork-decisions/2026-11-13-code-review-posts-findings.md): the skill's
# own --comment posting is optional in its prompt, and reviewers skipped it on
# PRs that had findings, so the run passes no --comment and posts every finding
# of the JSON findings block the skill ends its reply with, inline on the PR's
# head, or as a general PR comment naming the file and line when GitHub
# refuses the inline one. `args` still prints the hand-run form with --comment
# for a worker briefed before `review` existed. Once every
# finding is fixed or answered in its thread and the last push is in, `record`
# posts one PR comment carrying the marker line
#   <!-- fm-code-review v1 diff=<diff-id> head=<sha> -->
# where <diff-id> is `git patch-id --verbatim` of the PR's diff as GitHub
# serves it (a hash of the diff text when patch-id yields nothing, as for a
# diff of binary files only). The patch id ignores line numbers but not
# whitespace, so a rebase that leaves the change alone keeps the record valid,
# while any change to the diff, indentation included, needs a new review and a
# new record. GitHub refuses to serve the diff of a very large pull request
# (about 20,000 lines or 300 files); its <diff-id> is then the head commit
# itself, so every push to it needs a new review. Only a comment
# whose author is the repository's owner, a member, or a collaborator counts,
# so a stranger's comment on a public repository cannot pose as a record. The
# record is the reviewer's attestation; nothing here re-derives the review.
#
# A tiny follow-up pushed after a record may carry that review instead of
# running a new one (Arjun's 2026-10-26 relaxation of the 2026-10-17 gate).
# `record --carry` compares the head of the last full record (one whose comment
# carries no carry marker) with the PR's current head through GitHub's compare
# API, and carries the review only when the current head descends from that
# head and the follow-up, counted cumulatively since that full review so a
# chain of carries cannot grow past it, changes at most CODE_REVIEW_CARRY_LINES
# (10) added plus deleted lines. Without a risk-tiers.toml the path exemption
# above applies, so lines in exempt paths are not counted; with a table every
# changed line counts, because only the table may exempt a path there. Ten
# lines covers the follow-ups that retro measured looping reviews over - a
# test-count bump, a one-line reword, a fork-decisions PR number - while any
# real change of logic still gets a full review. Refused: a head that does not
# strictly descend from the reviewed head (a rebase, a merge from the base
# branch, or an unchanged head whose diff changed because the base moved), a
# file renamed into a counted path (its whole content is new to review), a
# counted file GitHub shows no text patch for, a compare listing at its
# 300-file cap, and a head that moves while the carry is measured. A carried
# record adds the line
#   <!-- fm-code-review-carry from=<full-record head> lines=<n> -->
# after the marker, so status and bin/fm-pr-merge.sh read it as an ordinary
# record and the next carry still measures from the full review.
#
# GitHub only: the findings post to GitHub pull requests, so a GitLab or
# Forgejo URL is refused here and bin/fm-pr-merge.sh does not apply the guard
# to those forges.
#
# Usage:
#   fm-code-review.sh review <pr-url> --model <model>
#       Runs `claude -p --model <model> "/code-review medium <number> <focus>"`
#       from the current directory, printing its output, then posts each
#       finding of its JSON findings block and prints one `posted:` line.
#       Exits 0 when every finding posted (none is fine), 1 when the review
#       failed, printed no findings block, or a finding could not be posted
#       (the output file is named, and nothing is retried), and 2 for a usage
#       error or a URL that is not a GitHub pull request. The run takes many
#       minutes, longer than a shell tool's default time limit.
#   fm-code-review.sh args <pr-url>
#       Prints, on one line, the arguments a hand-run /code-review takes for
#       the pull request: `medium --comment <number>` and then the merge-gate
#       focus. Exits 0, or 2 when the URL is not a GitHub pull request.
#   fm-code-review.sh classify [<path>...]
#       Paths from the arguments, or one per line on stdin when there are none,
#       classified as a repository without a table classifies them. Prints
#       `code-changing` or `exempt` and exits 0.
#   fm-code-review.sh status <pr-url>
#       Prints one line: `exempt: ...`, `reviewed: diff <id> ...`, or
#       `unreviewed: diff <id> ...`. Exits 0 for exempt or reviewed, 1 for
#       unreviewed, and 2 when the pull request cannot be read or the URL is
#       not a GitHub pull request.
#   fm-code-review.sh record <pr-url> [--carry] [--note <text>]
#       Posts the record for the PR's current diff, unless the PR is exempt
#       or already reviewed at that diff, with <text> on its own line after
#       the standard line saying which review ran, such as the worker's
#       `Sol: <N> rounds, <model>, <verdict>` from the tstack-sol-loop
#       pre-check bin/fm-dod-lib.sh asks for (docs/fork-decisions.md
#       2026-10-26 sol-loop); a note of more than one line or holding `<!--`
#       is refused, so it cannot pose as a marker, and a note for a diff that
#       needs no new record is not posted and draws a warning. Then it prints
#       the status line. Exits as status does, except that a record that
#       cannot be posted or read back exits 1. With --carry it posts only a
#       carried record, and refuses with exit 1 when the follow-up since the
#       last full record is not one a carry covers.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk 'NR == 1 { next } /^set -eu/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

code_review_path_exempt() {
  case "$1" in
    docs/records/*|docs/receipts/*|data/*|seed/*|*.md) return 0 ;;
  esac
  return 1
}

# Reads paths one per line on stdin; empty lines are ignored.
code_review_classify_stream() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    code_review_path_exempt "$path" || { echo code-changing; return 0; }
  done
  echo exempt
}

# Whether main keeps a risk-tiers.toml: returns 0 when it does, 1 when it does
# not, and 2 when that cannot be read.
code_review_has_table() {
  local err
  err=$(mktemp "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 2
  if gh api "repos/$FM_PR_OWNER/$FM_PR_REPO/contents/risk-tiers.toml?ref=main" --jq .type \
    > /dev/null 2> "$err"; then
    rm -f "$err"
    return 0
  fi
  if grep -q 'HTTP 404' "$err"; then
    rm -f "$err"
    return 1
  fi
  cat "$err" >&2
  rm -f "$err"
  return 2
}

CODE_REVIEW_TIER=
# Sets CODE_REVIEW_TIER to the classifier's `<tier>: <why>` line for the pull
# request's head as the API reports it, read once per run. Runs the classifier
# on a throwaway blob-less clone holding origin/main, that head, and main's
# table in its tree, fetched with gh's credentials and never a prompt; a pull
# request ref that does not yet name that head is refused rather than read.
code_review_tier() {
  local classifier=${FM_RISK_TIER:-${FLEET_NIX:-$HOME/nix}/bin/risk-tier} dir head fetched status=0
  [ -z "$CODE_REVIEW_TIER" ] || return 0
  if [ ! -x "$classifier" ]; then
    echo "error: $FM_PR_OWNER/$FM_PR_REPO keeps a risk-tiers.toml, but its classifier $classifier is not an executable file" >&2
    return 2
  fi
  if ! head=$(code_review_head) || ! fm_pr_head_valid "$head"; then
    echo "error: could not read the head commit of $FM_PR_URL" >&2
    return 2
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 2
  if git init -q "$dir" \
    && git -C "$dir" remote add origin "https://$FM_PR_HOST/$FM_PR_OWNER/$FM_PR_REPO.git" \
    && git -C "$dir" config remote.origin.promisor true \
    && git -C "$dir" config remote.origin.partialclonefilter blob:none \
    && GIT_TERMINAL_PROMPT=0 git -C "$dir" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
      fetch -q --filter=blob:none origin \
      +refs/heads/main:refs/remotes/origin/main \
      "+refs/pull/$FM_PR_NUMBER/head:refs/fm-code-review/head" \
    && git -C "$dir" show origin/main:risk-tiers.toml > "$dir/risk-tiers.toml" \
    && fetched=$(git -C "$dir" rev-parse --verify refs/fm-code-review/head); then
    if [ "$fetched" = "$head" ]; then
      CODE_REVIEW_TIER=$("$classifier" --root "$dir" --head "$head") || status=2
    else
      echo "error: the pull request ref of $FM_PR_URL names $fetched, not its head $head yet; read it again" >&2
      status=2
    fi
  else
    echo "error: could not fetch main and the head of $FM_PR_URL to classify its tier" >&2
    status=2
  fi
  rm -rf "$dir"
  case "$status:$CODE_REVIEW_TIER" in
    0:tinker:*|0:shared:*|0:business:*) return 0 ;;
    0:*) echo "error: $classifier printed no tier for $FM_PR_URL: $CODE_REVIEW_TIER" >&2 ;;
  esac
  CODE_REVIEW_TIER=
  return 2
}

# The merge-gate focus, one rule per line; `args` joins it into one line,
# because the skill folds its arguments into one review-target line anyway.
code_review_focus() {
  cat <<EOF
Merge-gate focus for this review: the author must fix or answer in writing every finding you report, and many past findings here were declined. These rules remove the kinds of finding that authors decline; they do not raise the bar for a real defect. Keep hunting correctness bugs and wrong instructions with full recall, and report every one that survives the rules below, up to the cap; spend the room these rules free on correctness: before you finish, go over each changed function, each removed line, and each changed procedure step once more for a defect you have not listed.
1. A finding is something that makes code, configuration, or an executed document (a skill, procedure, agent contract, or record that an agent acts on) do the wrong thing in ordinary use, or a document statement that is false and would lead its reader to a wrong action. For a document agents follow step by step, an agent applying a step literally is ordinary use, so a step that omits, contradicts, or misstates what the rest of the system requires is a finding even when a general rule elsewhere says otherwise.
2. Skip the cleanup, altitude, and preference angles entirely: duplication or reuse of a helper, simplification, refactoring, naming, wording, line wrapping, style, a fix at a different depth, and cost or speed unless it makes something fail or time out in ordinary use.
3. Skip test-quality findings (a weak, flaky, or missing test, an unfaithful stub, a misleading test label) unless a test now passes while the behavior it covers is broken.
4. Skip defensive hardening (a fallback, validation, or a guard) for an input, platform, tool version, or future caller that nothing in the repository shows occurs; when the finding needs such a trigger, look for its producer or caller first and drop it if there is none. A network call that hangs or fails, another process or a concurrent run, a stuck or dead process, and records or state written before this change are ordinary triggers, not speculative ones.
5. Read the pull request's title and description before judging intent: run gh pr view $FM_PR_NUMBER --repo $FM_PR_HOST/$FM_PR_OWNER/$FM_PR_REPO --json title,body. Behavior that the description, or a spec, decision, or record it cites, states as intended is not a finding unless it breaks something that text does not account for.
6. Before you report that something is missing or unguarded, check the callers, wrappers, and owning documents outside the changed lines; drop it only when you can cite the code or step that already prevents the failure on the path this change affects.
7. Report a problem in unchanged code only when this diff introduces it, exposes it, or makes it reachable.
8. A clear violation of a written rule in a CLAUDE.md or AGENTS.md that governs the changed file is still a finding when you can quote the rule and the line that breaks it.
EOF
}

CODE_REVIEW_POSTED_INLINE=0
CODE_REVIEW_POSTED_GENERAL=0
# Posts each finding of a JSON findings array file as an inline comment on
# the PR's head, or as a general PR comment naming its file and line when
# GitHub refuses the inline one (a line outside the diff, a path outside the
# repository). A `<!--` in the reviewer's text becomes `< !--`, so a finding can
# never pose as a record marker. Returns 1 when any finding could not be
# posted either way.
code_review_post_findings() {  # <findings-file>
  local findings=$1 head top count i finding path line body err failed=0
  if ! head=$(code_review_head) || ! fm_pr_head_valid "$head"; then
    echo "error: could not read the head commit of $FM_PR_URL, so no finding was posted" >&2
    return 1
  fi
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
  err=$(mktemp "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 1
  count=$(jq 'length' "$findings")
  i=0
  while [ "$i" -lt "$count" ]; do
    finding=$(jq -c ".[$i]" "$findings")
    i=$((i + 1))
    path=$(printf '%s' "$finding" | jq -r '.file // "" | tostring')
    [ -z "$top" ] || path=${path#"$top"/}
    path=${path#./}
    line=$(printf '%s' "$finding" | jq -r '.line // "" | tostring')
    body=$(printf '%s' "$finding" | jq -r '[(.summary // "" | tostring), (.failure_scenario // "" | tostring | select(. != "") | "Failure scenario: " + .)] | map(select(. != "")) | join("\n\n")')
    body=${body//<!--/< !--}
    case "$line" in
      ''|0|*[!0-9]*) ;;
      *)
        if [ -n "$path" ] && jq -n --arg body "$body" --arg commit "$head" --arg path "$path" --argjson line "$line" \
          '{body: $body, commit_id: $commit, path: $path, line: $line, side: "RIGHT"}' \
          | gh api -X POST "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/comments" --input - >/dev/null 2>"$err"; then
          CODE_REVIEW_POSTED_INLINE=$((CODE_REVIEW_POSTED_INLINE + 1))
          continue
        fi
        echo "warning: GitHub refused the inline comment at $path:$line, so it is posted as a general comment: $(tr '\n' ' ' < "$err")" >&2
        ;;
    esac
    # shellcheck disable=SC2016  # the backticks are Markdown, not expansion
    if printf '`%s:%s`: %s\n' "${path:-?}" "${line:-?}" "$body" \
      | gh pr comment "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" --body-file - >/dev/null; then
      CODE_REVIEW_POSTED_GENERAL=$((CODE_REVIEW_POSTED_GENERAL + 1))
    else
      echo "error: could not post the finding at ${path:-?}:${line:-?} on $FM_PR_URL" >&2
      failed=1
    fi
  done
  rm -f "$err"
  return "$failed"
}

# Runs the merge-gate review headless and posts its findings. The skill's own
# --comment posting is optional by its prompt, so a reviewer may print its
# findings and post none; the run here passes no --comment and posts every
# finding of the JSON findings block the skill always ends its reply with.
code_review_run() {  # <model>
  local model=$1 out findings rc blocks
  local -a piped
  out=$(mktemp "${TMPDIR:-/tmp}/fm-code-review-output.XXXXXX") || return 1
  findings=$(mktemp "${TMPDIR:-/tmp}/fm-code-review-findings.XXXXXX") || return 1
  set +e
  claude -p --model "$model" "/code-review medium $FM_PR_NUMBER $(code_review_focus_line)" \
    < /dev/null | tee "$out"
  piped=("${PIPESTATUS[@]}")
  set -e
  rc=${piped[0]}
  [ "$rc" -ne 0 ] || rc=${piped[1]}
  if [ "$rc" -ne 0 ]; then
    rm -f "$findings"
    echo "error: the headless /code-review exited $rc, so no finding was posted; its output is in $out" >&2
    return 1
  fi
  # The last fenced json block that parses as an array is the findings list;
  # awk writes each block to its own numbered file, read back from the last.
  blocks=$(awk -v base="$findings" '/^```json[[:space:]]*$/ { inblock = 1; n++; printf "" > (base "." n); next }
       /^```[[:space:]]*$/ && inblock { inblock = 0; close(base "." n); next }
       inblock { print > (base "." n) }
       END { print n + 0 }' "$out")
  : > "$findings"
  while [ "$blocks" -gt 0 ]; do
    if [ ! -s "$findings" ] && jq -e 'type == "array"' "$findings.$blocks" >/dev/null 2>&1; then
      cp "$findings.$blocks" "$findings"
    fi
    rm -f "$findings.$blocks"
    blocks=$((blocks - 1))
  done
  if ! jq -e 'type == "array"' "$findings" >/dev/null 2>&1; then
    rm -f "$findings"
    echo "error: the review printed no JSON findings block, so no finding was posted; its output is in $out" >&2
    return 1
  fi
  rc=0
  code_review_post_findings "$findings" || rc=1
  echo "posted: $CODE_REVIEW_POSTED_INLINE inline and $CODE_REVIEW_POSTED_GENERAL general comments for $(jq 'length' "$findings") findings on $FM_PR_URL"
  rm -f "$findings"
  if [ "$rc" -ne 0 ]; then
    echo "error: a finding could not be posted; the review output is in $out" >&2
    return 1
  fi
  rm -f "$out"
}

code_review_focus_line() {
  code_review_focus | tr '\n' ' ' | sed 's/ *$//'
}

code_review_parse_url() {
  if ! fm_pr_url_parse "${1-}" || [ "$FM_PR_PROVIDER" != github ]; then
    echo "error: not a GitHub pull request URL: ${1-}" >&2
    return 2
  fi
}

# Each changed file as "F <path>", plus "P <old path>" for a rename.
code_review_files() {
  gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/files" \
    --jq '.[] | ("F " + .filename), (.previous_filename // empty | "P " + .)'
}

# A failed diff read falls back to the head only when GitHub refused the diff
# for its size (HTTP 406); any other failure leaves the review state unreadable.
# gh refuses to print a diff carrying terminal escape sequences, which test
# fixtures legitimately hold; the diff only ever reaches git patch-id here, so
# --allow-escape-sequences is passed whenever this gh offers it, read from its
# local help because older gh lacks the flag and would reject it.
code_review_diff_id() {
  local diff='' err id head
  local -a flags=()
  if gh pr diff --help 2>/dev/null | grep -q -- '--allow-escape-sequences'; then
    flags=(--allow-escape-sequences)
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 1
  if ! diff=$(gh pr diff "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" ${flags[@]+"${flags[@]}"} 2>"$err"); then
    case "$(cat "$err")" in
      *"HTTP 406"*|*"too_large"*|*"exceeded the maximum"*) diff= ;;
      *) cat "$err" >&2; rm -f "$err"; return 1 ;;
    esac
  fi
  rm -f "$err"
  if [ -z "$diff" ]; then
    head=$(code_review_head) && fm_pr_head_valid "$head" || return 1
    printf '%s\n' "$head"
    return 0
  fi
  id=$(printf '%s\n' "$diff" | git patch-id --verbatim | awk 'NR == 1 { print $1 }')
  [ -n "$id" ] || id=$(printf '%s\n' "$diff" | git hash-object --stdin)
  printf '%s\n' "$id"
}

code_review_head() {
  gh pr view "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" --json headRefOid --jq .headRefOid
}

# Diff ids carried by record comments from trusted authors, one per line.
code_review_recorded_ids() {
  local bodies
  bodies=$(gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/issues/$FM_PR_NUMBER/comments" \
    --jq '.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") | .body') \
    || return 1
  printf '%s\n' "$bodies" | tr -d '\r' \
    | sed -n 's/^<!-- fm-code-review v1 diff=\([0-9a-f]\{40,64\}\) head=[0-9a-f]\{40,64\} -->$/\1/p'
}

CODE_REVIEW_CARRY_LINES=10

# The head of the last record comment from a trusted author that carries no
# carry marker, or nothing when the PR has none.
code_review_full_record_head() {
  local heads
  heads=$(gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/issues/$FM_PR_NUMBER/comments" \
    --jq '.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") | .body | gsub("\r"; "") | select(test("(^|\n)<!-- fm-code-review-carry ") | not) | capture("(^|\n)<!-- fm-code-review v1 diff=[0-9a-f]{40,64} head=(?<head>[0-9a-f]{40,64}) -->(\n|$)") | .head') \
    || return 1
  printf '%s\n' "$heads" | sed -n '$p'
}

CODE_REVIEW_CARRY_FROM=
CODE_REVIEW_CARRY_COUNT=
# Sets CODE_REVIEW_CARRY_FROM and CODE_REVIEW_CARRY_COUNT when the follow-up
# from the last full record to <head> is one a carry covers; returns 1 with
# the reason on stderr when it is not, and 2 when it cannot be read.
code_review_carry_check() {  # <head>
  local head=$1 from listing state count path previous changes patch lines=0
  if ! from=$(code_review_full_record_head); then
    echo "error: could not read the comments of $FM_PR_URL" >&2
    return 2
  fi
  if [ -z "$from" ]; then
    echo "error: $FM_PR_URL has no full code review record to carry; run /code-review and record it" >&2
    return 1
  fi
  if ! listing=$(gh api "repos/$FM_PR_OWNER/$FM_PR_REPO/compare/$from...$head" \
    --jq '.status, (.files | length), (.files[] | [(.changes | tostring), (if .patch then "text" else "none" end), .filename, (.previous_filename // "")] | @tsv)'); then
    echo "error: could not compare the reviewed head $from with $head on $FM_PR_URL" >&2
    return 2
  fi
  state=$(printf '%s\n' "$listing" | sed -n 1p)
  count=$(printf '%s\n' "$listing" | sed -n 2p)
  case "$state" in
    ahead) ;;
    identical)
      echo "error: the head $head is the reviewed head, so its diff changed only because the base moved; run /code-review again" >&2
      return 1
      ;;
    *)
      echo "error: $head does not descend from the reviewed head $from (compare status ${state:-unknown}), so the follow-up cannot be measured; run /code-review again" >&2
      return 1
      ;;
  esac
  case "$count" in
    ''|*[!0-9]*) echo "error: could not read the files changed since $from on $FM_PR_URL" >&2; return 2 ;;
  esac
  if [ "$count" -ge 300 ]; then
    echo "error: the follow-up since $from reaches GitHub's 300-file compare cap, so it cannot be measured; run /code-review again" >&2
    return 1
  fi
  # The optional previous name comes last: read collapses adjacent tabs, so an
  # empty field anywhere else would shift the ones after it.
  while IFS=$'\t' read -r changes patch path previous; do
    [ -n "$path" ] || continue
    if [ "$CODE_REVIEW_HAS_TABLE" != 0 ] && code_review_path_exempt "$path" \
      && { [ -z "$previous" ] || code_review_path_exempt "$previous"; }; then
      continue
    fi
    if [ -n "$previous" ] && { [ "$CODE_REVIEW_HAS_TABLE" = 0 ] || ! code_review_path_exempt "$path"; }; then
      echo "error: $previous was renamed to $path since the reviewed head $from, so its whole content is new to review; run /code-review again" >&2
      return 1
    fi
    if [ "$patch" != text ]; then
      echo "error: $path changed since the reviewed head $from without a text patch, so its size cannot be measured; run /code-review again" >&2
      return 1
    fi
    case "$changes" in
      ''|*[!0-9]*) echo "error: could not read the size of $path's change since $from" >&2; return 2 ;;
    esac
    lines=$((lines + changes))
  done <<EOF
$(printf '%s\n' "$listing" | sed '1,2d')
EOF
  if [ "$lines" -gt "$CODE_REVIEW_CARRY_LINES" ]; then
    echo "error: the follow-up since the reviewed head $from changes $lines counted lines, more than the carry cap of $CODE_REVIEW_CARRY_LINES; run /code-review again" >&2
    return 1
  fi
  CODE_REVIEW_CARRY_FROM=$from
  CODE_REVIEW_CARRY_COUNT=$lines
}

CODE_REVIEW_DIFF_ID=
CODE_REVIEW_LINE=
CODE_REVIEW_HAS_TABLE=
# Sets CODE_REVIEW_LINE to the status line and returns 0 exempt or reviewed, 1
# unreviewed, 2 unreadable; sets CODE_REVIEW_DIFF_ID for a code-changing PR.
code_review_status() {
  local files verdict ids status=0 changes='changes code'
  CODE_REVIEW_DIFF_ID=
  CODE_REVIEW_LINE=
  code_review_has_table || status=$?
  CODE_REVIEW_HAS_TABLE=$status
  case "$status" in
    0)
      code_review_tier || return 2
      verdict=code-changing
      case "$CODE_REVIEW_TIER" in tinker:*) verdict=exempt ;; esac
      changes="is ${CODE_REVIEW_TIER%%:*} under its risk-tiers.toml (${CODE_REVIEW_TIER#*: })"
      ;;
    1)
      if ! files=$(code_review_files); then
        echo "error: could not read the changed files of $FM_PR_URL" >&2
        return 2
      fi
      verdict=$(printf '%s\n' "$files" | sed 's/^[FP] //' | code_review_classify_stream)
      if [ "$(printf '%s\n' "$files" | grep -c '^F ')" -ge 3000 ]; then
        verdict=code-changing
      fi
      ;;
    *)
      echo "error: could not read whether $FM_PR_OWNER/$FM_PR_REPO keeps a risk-tiers.toml on main" >&2
      return 2
      ;;
  esac
  if [ "$verdict" = exempt ]; then
    if [ "$status" -eq 0 ]; then
      CODE_REVIEW_LINE="exempt: $FM_PR_URL is tinker under its risk-tiers.toml: ${CODE_REVIEW_TIER#*: }"
    else
      CODE_REVIEW_LINE="exempt: every changed path of $FM_PR_URL is a record, receipt, data, seed, or Markdown file"
    fi
    return 0
  fi
  if ! CODE_REVIEW_DIFF_ID=$(code_review_diff_id); then
    echo "error: could not fingerprint the diff of $FM_PR_URL" >&2
    return 2
  fi
  if ! ids=$(code_review_recorded_ids); then
    echo "error: could not read the comments of $FM_PR_URL" >&2
    return 2
  fi
  if printf '%s\n' "$ids" | grep -qxF "$CODE_REVIEW_DIFF_ID"; then
    CODE_REVIEW_LINE="reviewed: diff $CODE_REVIEW_DIFF_ID of $FM_PR_URL carries a code review record"
    return 0
  fi
  CODE_REVIEW_LINE="unreviewed: diff $CODE_REVIEW_DIFF_ID of $FM_PR_URL $changes and carries no code review record for it"
  return 1
}

code_review_record() {  # <note> <carry 0|1>
  local note=$1 carry=$2 status=0 head head0='' body marker
  local line="Code review: Claude Code \`/code-review\` (medium) ran on this diff; each finding is posted inline and was fixed or answered in its thread."
  # A carry binds the diff it fingerprints, the head it measures, and the head
  # it records to one push: the head is read before and after both.
  if [ "$carry" = 1 ] && { ! head0=$(code_review_head) || ! fm_pr_head_valid "$head0"; }; then
    echo "error: could not read the head commit of $FM_PR_URL" >&2
    return 1
  fi
  code_review_status || status=$?
  case "$status" in
    0)
      [ -z "$note" ] || echo "warning: $FM_PR_URL needs no new record at this diff, so the note was not posted" >&2
      printf '%s\n' "$CODE_REVIEW_LINE"
      return 0
      ;;
    1) ;;
    *) return "$status" ;;
  esac
  if ! head=$(code_review_head) || ! fm_pr_head_valid "$head"; then
    echo "error: could not read the head commit of $FM_PR_URL" >&2
    return 1
  fi
  marker="<!-- fm-code-review v1 diff=$CODE_REVIEW_DIFF_ID head=$head -->"
  if [ "$carry" = 1 ]; then
    code_review_carry_check "$head" || return "$?"
    if [ "$head" != "$head0" ] || [ "$(code_review_head 2>/dev/null)" != "$head" ]; then
      echo "error: the head of $FM_PR_URL moved while the carry was measured; run record --carry again" >&2
      return 1
    fi
    marker="$marker
<!-- fm-code-review-carry from=$CODE_REVIEW_CARRY_FROM lines=$CODE_REVIEW_CARRY_COUNT -->"
    line="Code review carried from the full review recorded at $CODE_REVIEW_CARRY_FROM: this follow-up changes $CODE_REVIEW_CARRY_COUNT counted lines since then, within the carry cap of $CODE_REVIEW_CARRY_LINES."
  fi
  body="$marker
$line"
  [ -z "$note" ] || body="$body
$note"
  if ! printf '%s\n' "$body" | gh pr comment "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" --body-file - >/dev/null; then
    echo "error: could not post the code review record on $FM_PR_URL" >&2
    return 1
  fi
  status=0
  code_review_status || status=$?
  if [ "$status" -ne 0 ]; then
    echo "error: the code review record posted on $FM_PR_URL does not read back for its current diff" >&2
    return 1
  fi
  printf '%s\n' "$CODE_REVIEW_LINE"
}

cmd=${1-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  args)
    [ "$#" -eq 1 ] || { echo "error: usage: fm-code-review.sh args <pr-url>" >&2; exit 2; }
    code_review_parse_url "$1" || exit 2
    printf 'medium --comment %s %s\n' "$FM_PR_NUMBER" "$(code_review_focus_line)"
    ;;
  review)
    [ "$#" -ge 1 ] || { echo "error: usage: fm-code-review.sh review <pr-url> --model <model>" >&2; exit 2; }
    code_review_parse_url "$1" || exit 2
    shift
    model=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model)
          [ -n "${2:-}" ] || { echo "error: --model requires a model id" >&2; exit 2; }
          model=$2
          shift 2
          ;;
        *) echo "error: unknown review argument: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$model" ] || { echo "error: review needs --model <model>, the home's pinned review model" >&2; exit 2; }
    rc=0
    code_review_run "$model" || rc=$?
    exit "$rc"
    ;;
  classify)
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@" | code_review_classify_stream
    else
      code_review_classify_stream
    fi
    ;;
  status)
    [ "$#" -eq 1 ] || { echo "error: usage: fm-code-review.sh status <pr-url>" >&2; exit 2; }
    code_review_parse_url "$1" || exit 2
    rc=0
    code_review_status || rc=$?
    [ -z "$CODE_REVIEW_LINE" ] || printf '%s\n' "$CODE_REVIEW_LINE"
    exit "$rc"
    ;;
  record)
    [ "$#" -ge 1 ] || { echo "error: usage: fm-code-review.sh record <pr-url> [--carry] [--note <text>]" >&2; exit 2; }
    code_review_parse_url "$1" || exit 2
    shift
    note=
    carry=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --carry)
          carry=1
          shift
          ;;
        --note)
          [ -n "${2:-}" ] || { echo "error: --note requires text" >&2; exit 2; }
          case $2 in
            *$'\n'*|*'<!--'*) echo "error: --note must be one line without '<!--', so it cannot pose as a record marker" >&2; exit 2 ;;
          esac
          note=$2
          shift 2
          ;;
        *) echo "error: unknown record argument: $1" >&2; exit 2 ;;
      esac
    done
    rc=0
    code_review_record "$note" "$carry" || rc=$?
    exit "$rc"
    ;;
  -h|--help) usage ;;
  *)
    echo "error: usage: fm-code-review.sh review|args|classify|status|record (see --help)" >&2
    exit 2
    ;;
esac
