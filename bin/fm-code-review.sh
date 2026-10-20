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
# The review is Claude Code's built-in /code-review skill at its medium level
# with --comment, which posts each finding as an inline PR comment. Once every
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
# GitHub only: /code-review --comment posts to GitHub pull requests, so a
# GitLab or Forgejo URL is refused here and bin/fm-pr-merge.sh does not apply
# the guard to those forges.
#
# Usage:
#   fm-code-review.sh classify [<path>...]
#       Paths from the arguments, or one per line on stdin when there are none,
#       classified as a repository without a table classifies them. Prints
#       `code-changing` or `exempt` and exits 0.
#   fm-code-review.sh status <pr-url>
#       Prints one line: `exempt: ...`, `reviewed: diff <id> ...`, or
#       `unreviewed: diff <id> ...`. Exits 0 for exempt or reviewed, 1 for
#       unreviewed, and 2 when the pull request cannot be read or the URL is
#       not a GitHub pull request.
#   fm-code-review.sh record <pr-url> [--note <text>]
#       Posts the record for the PR's current diff, with <text> as its body
#       when given, unless the PR is exempt or already reviewed at that diff;
#       then prints the status line. Exits as status does, except that a
#       record that cannot be posted or read back exits 1.
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
# request's head, read once per run. Runs the classifier on a throwaway
# blob-less clone holding origin/main, the head, and main's table in its tree.
code_review_tier() {
  local classifier=${FM_RISK_TIER:-${FLEET_NIX:-$HOME/nix}/bin/risk-tier} dir head status=0
  [ -z "$CODE_REVIEW_TIER" ] || return 0
  if [ ! -x "$classifier" ]; then
    echo "error: $FM_PR_OWNER/$FM_PR_REPO keeps a risk-tiers.toml, but its classifier $classifier is not an executable file" >&2
    return 2
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 2
  if git init -q "$dir" \
    && git -C "$dir" remote add origin "https://$FM_PR_HOST/$FM_PR_OWNER/$FM_PR_REPO.git" \
    && git -C "$dir" config remote.origin.promisor true \
    && git -C "$dir" config remote.origin.partialclonefilter blob:none \
    && git -C "$dir" fetch -q --filter=blob:none origin \
      +refs/heads/main:refs/remotes/origin/main \
      "+refs/pull/$FM_PR_NUMBER/head:refs/fm-code-review/head" \
    && git -C "$dir" show origin/main:risk-tiers.toml > "$dir/risk-tiers.toml" \
    && head=$(git -C "$dir" rev-parse --verify refs/fm-code-review/head); then
    CODE_REVIEW_TIER=$("$classifier" --root "$dir" --head "$head") || status=2
  else
    echo "error: could not fetch main and the head of $FM_PR_URL to classify its tier" >&2
    status=2
  fi
  rm -rf "$dir"
  case "$CODE_REVIEW_TIER" in
    tinker:*|shared:*|business:*) ;;
    *)
      [ "$status" -ne 0 ] || echo "error: $classifier printed no tier for $FM_PR_URL: $CODE_REVIEW_TIER" >&2
      CODE_REVIEW_TIER=
      return 2
      ;;
  esac
  return "$status"
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

CODE_REVIEW_DIFF_ID=
CODE_REVIEW_LINE=
# Sets CODE_REVIEW_LINE to the status line and returns 0 exempt or reviewed, 1
# unreviewed, 2 unreadable; sets CODE_REVIEW_DIFF_ID for a code-changing PR.
code_review_status() {
  local files verdict ids status=0 changes='changes code'
  CODE_REVIEW_DIFF_ID=
  CODE_REVIEW_LINE=
  code_review_has_table || status=$?
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

code_review_record() {
  local note=$1 status=0 head body
  code_review_status || status=$?
  case "$status" in
    0) printf '%s\n' "$CODE_REVIEW_LINE"; return 0 ;;
    1) ;;
    *) return "$status" ;;
  esac
  if ! head=$(code_review_head) || ! fm_pr_head_valid "$head"; then
    echo "error: could not read the head commit of $FM_PR_URL" >&2
    return 1
  fi
  [ -n "$note" ] || note="Code review: Claude Code \`/code-review\` (medium) ran on this diff; each finding is posted inline and was fixed or answered in its thread."
  body="<!-- fm-code-review v1 diff=$CODE_REVIEW_DIFF_ID head=$head -->
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
    [ "$#" -ge 1 ] || { echo "error: usage: fm-code-review.sh record <pr-url> [--note <text>]" >&2; exit 2; }
    code_review_parse_url "$1" || exit 2
    shift
    note=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --note)
          [ -n "${2:-}" ] || { echo "error: --note requires text" >&2; exit 2; }
          note=$2
          shift 2
          ;;
        *) echo "error: unknown record argument: $1" >&2; exit 2 ;;
      esac
    done
    rc=0
    code_review_record "$note" || rc=$?
    exit "$rc"
    ;;
  -h|--help) usage ;;
  *)
    echo "error: usage: fm-code-review.sh classify|status|record (see --help)" >&2
    exit 2
    ;;
esac
