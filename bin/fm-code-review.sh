#!/usr/bin/env bash
# Independent code review on the merge path (fork patch, docs/fork-decisions.md
# 2026-10-17). This file is the single owner of which pull requests need that
# review and of the record that proves one ran; bin/fm-pr-merge.sh refuses a
# GitHub merge its status calls unreviewed, and bin/fm-dod-lib.sh tells a ship
# worker to run the review before its ready report.
#
# When the pull request's base branch keeps a risk-tiers.toml at its root
# (docs/fork-decisions.md 2026-10-19), that table alone decides: a tinker pull
# request is exempt, and a shared or business one is code-changing. The table
# is read from the base branch, so a pull request cannot lower its own tier by
# editing it, and is parsed the way the fleet's bin/risk-tier parses it: a
# changed path takes the highest tier of every rule whose `paths` globs match
# it (** crosses directories, * and ? do not), or the table's `default` when
# none does; a path the `ignore` globs match counts toward no tier; the pull
# request takes the highest tier of its counted paths, starting from tinker,
# so one changing only ignored paths is exempt; and a tinker pull request
# whose counted files change more lines in total than `max_tinker_lines`, as
# GitHub counts them, is `default`. A table that does not parse, names an
# unknown `default`, names a tier above its `default`, or has a rule without
# `paths` leaves the review state unreadable, as does a python3 without tomllib.
#
# Without a table, a changed path is exempt when it lies under docs/records/,
# docs/receipts/, data/, or seed/, or names a Markdown file (*.md), and a pull
# request is code-changing when any changed path is not exempt, so a receipts,
# records, or prose-only pull request merges on green alone and everything
# else carries a review first.
#
# Either way a rename counts both its names, and GitHub lists at most 3000
# changed files, so a pull request at that cap counts as code-changing, since
# the files it leaves unlisted cannot be classified.
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
#   fm-code-review.sh classify [--table <risk-tiers.toml>] [<path>...]
#       Paths from the arguments, or one per line on stdin when there are none,
#       classified by the table when given (counting no changed lines) or by
#       the paths alone. Prints `code-changing` or `exempt` and exits 0, or 2
#       when the table is unreadable.
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

# The tier of a change under a risk-tiers.toml (see the header). Reads
# "<changed lines>\t<path>" lines on stdin; prints "<tier>\t<why>", or the
# table's fault on stderr and exits 2.
CODE_REVIEW_TIER_PY=$(cat <<'PY'
import re
import sys

TIERS = ("tinker", "shared", "business")


def die(message):
    print(f"error: {sys.argv[1]}: {message}", file=sys.stderr)
    sys.exit(2)


def glob_regex(pattern):
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def globs(value, where):
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        die(f"{where} must be a list of globs")
    return [glob_regex(item) for item in value]


def matches(path, patterns):
    return any(pattern.match(path) for pattern in patterns)


try:
    import tomllib
except ImportError:
    die("python3 has no tomllib (Python 3.11 or later reads risk-tiers.toml)")
try:
    with open(sys.argv[1], "rb") as handle:
        table = tomllib.load(handle)
except (OSError, tomllib.TOMLDecodeError) as error:
    die(f"does not parse: {error}")
default = table.get("default")
if default not in TIERS:
    die(f"default must be one of {', '.join(TIERS)}, not {default!r}")
rules = []
for tier in TIERS:
    entries = table.get(tier, [])
    if not isinstance(entries, list):
        die(f"{tier} must be an array of tables")
    if entries and TIERS.index(tier) > TIERS.index(default):
        die(f"default {default!r} is not the highest tier the table names ({tier!r})")
    for number, rule in enumerate(entries, 1):
        if not isinstance(rule, dict) or not rule.get("paths"):
            die(f"[[{tier}]] #{number} has no paths")
        rules.append((tier, globs(rule["paths"], f"[[{tier}]] #{number} paths")))
ignore = globs(table.get("ignore", []), "ignore")
limit = table.get("max_tinker_lines")
if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool)):
    die("max_tinker_lines must be a number")

tier, why, size, counted = "tinker", None, 0, 0
for line in sys.stdin:
    lines, _, path = line.rstrip("\n").partition("\t")
    if not path or matches(path, ignore):
        continue
    counted += 1
    size += int(lines) if lines.isdigit() else 0
    hits = [rule_tier for rule_tier, patterns in rules if matches(path, patterns)]
    path_tier = max(hits, key=TIERS.index) if hits else default
    if TIERS.index(path_tier) > TIERS.index(tier):
        tier = path_tier
        why = f"{path} is {path_tier}" if hits else f"{path} matches no rule (default {default})"
if not counted:
    why = "it changes only paths the table ignores"
elif tier == "tinker" and limit and size > limit:
    tier, why = default, f"its {size} changed lines pass max_tinker_lines ({limit})"
elif tier == "tinker":
    why = "every changed path it counts is tinker"
print(f"{tier}\t{why}")
PY
)

# Args: table; stdin as for CODE_REVIEW_TIER_PY.
code_review_tier() {
  python3 -c "$CODE_REVIEW_TIER_PY" "$1"
}

# Args: table, or none for the paths alone; paths one per line on stdin.
code_review_classify_paths() {
  local table=$1 tier
  if [ -z "$table" ]; then
    code_review_classify_stream
    return 0
  fi
  tier=$(awk '{ print "0\t" $0 }' | code_review_tier "$table") || return 2
  case "$tier" in
    tinker*) echo exempt ;;
    *) echo code-changing ;;
  esac
}

# Fetches the base branch's risk-tiers.toml to the file named by $1. Returns 0
# when it exists, 1 when the branch has none, and 2 when it cannot be read.
code_review_fetch_table() {
  local out=$1 ref err
  if ! ref=$(gh api "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER" --jq '.base.ref | @uri') || [ -z "$ref" ]; then
    echo "error: could not read the base branch of $FM_PR_URL" >&2
    return 2
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 2
  if gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$FM_PR_OWNER/$FM_PR_REPO/contents/risk-tiers.toml?ref=$ref" > "$out" 2> "$err"; then
    rm -f "$err"
    return 0
  fi
  if grep -q 'HTTP 404' "$err"; then
    rm -f "$err"
    return 1
  fi
  cat "$err" >&2
  rm -f "$err"
  echo "error: could not read the risk-tiers.toml of $FM_PR_URL's base branch" >&2
  return 2
}

code_review_parse_url() {
  if ! fm_pr_url_parse "${1-}" || [ "$FM_PR_PROVIDER" != github ]; then
    echo "error: not a GitHub pull request URL: ${1-}" >&2
    return 2
  fi
}

# Each changed file as "F\t<changed lines>\t<path>", plus "P\t0\t<old path>"
# for a rename.
code_review_files() {
  gh api --paginate "repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$FM_PR_NUMBER/files" \
    --jq '.[] | ("F\t" + ((.changes // 0) | tostring) + "\t" + .filename), (.previous_filename // empty | "P\t0\t" + .)'
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
  local files verdict ids table tier='' why changes='changes code' status=0
  CODE_REVIEW_DIFF_ID=
  CODE_REVIEW_LINE=
  if ! files=$(code_review_files); then
    echo "error: could not read the changed files of $FM_PR_URL" >&2
    return 2
  fi
  table=$(mktemp "${TMPDIR:-/tmp}/fm-code-review.XXXXXX") || return 2
  code_review_fetch_table "$table" || status=$?
  if [ "$status" -eq 0 ]; then
    tier=$(printf '%s\n' "$files" | cut -f2- | code_review_tier "$table") || status=2
  fi
  rm -f "$table"
  case "$status" in
    0)
      why=${tier#*$'\t'}
      tier=${tier%%$'\t'*}
      verdict=code-changing
      [ "$tier" != tinker ] || verdict=exempt
      changes="is $tier under its base branch's risk-tiers.toml ($why)"
      ;;
    1) verdict=$(printf '%s\n' "$files" | cut -f3- | code_review_classify_stream) ;;
    *) return 2 ;;
  esac
  if [ "$(printf '%s\n' "$files" | grep -c '^F')" -ge 3000 ]; then
    verdict=code-changing
    changes="lists GitHub's limit of 3000 changed files"
  fi
  if [ "$verdict" = exempt ]; then
    if [ -n "$tier" ]; then
      CODE_REVIEW_LINE="exempt: $FM_PR_URL is tinker under its base branch's risk-tiers.toml: $why"
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
    table=
    if [ "${1-}" = --table ]; then
      [ -n "${2:-}" ] || { echo "error: --table requires a risk-tiers.toml path" >&2; exit 2; }
      table=$2
      shift 2
    fi
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@" | code_review_classify_paths "$table"
    else
      code_review_classify_paths "$table"
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
