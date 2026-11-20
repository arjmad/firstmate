#!/usr/bin/env bash
# fm-fork-decisions.sh - check and list this fork's decision records.
#
# Each fork decision and each fork patch is its own file under
# docs/fork-decisions/, named <YYYY-MM-DD>-<slug>.md, so no two PRs edit the
# same file to record one. docs/fork-decisions.md is the stable entry point:
# it states the layout and the fork-patch contract and holds no records, so a
# PR never needs to touch it. That document owns the record format.
#
# Usage:
#   fm-fork-decisions.sh check [--root <repo>]
#       Fail, naming the file and line, when the entry point holds a dated
#       decision or a table row, when a record's name is not
#       <YYYY-MM-DD>-<slug>.md, when a record is neither a prose decision
#       opening with its file's date nor a fork-patch table, or when a
#       fork-patch table has the wrong header, cell count, or an empty status.
#       It also fails when a `carried` or `conflicted` row's Files cell names,
#       in backticks, a path under one of the repository's tracked top-level
#       entries that matches nothing in the checkout; a glob or one brace group
#       passes when anything matches, and a path followed by `(removed)` is
#       one the patch deleted, so it is not checked.
#       Prints `fm-fork-decisions: ok records=<n> patches=<n>` on success.
#   fm-fork-decisions.sh pr-check --base <rev> [--head <rev>] [--root <repo>]
#       Fail when the change from the merge base of <rev> and --head (default
#       HEAD) to --head changes an upstream-owned file but adds or edits no
#       docs/fork-decisions/ record (deleting one does not count), naming
#       those files. A file is
#       upstream-owned when it exists in the upstream sync commit, the newest
#       commit in this checkout that a fork-patch row names as its last
#       checked sync, so CI needs no upstream remote, only full history.
#       docs/fork-decisions.md and the records are the fork's own and never
#       count. An upstream-sync PR passes because it updates every row's sync.
#   fm-fork-decisions.sh patches [--root <repo>]
#       Print every fork-patch row as one table, oldest record first, with the
#       record's date and its PR: the record's `PR:` line when it has one,
#       otherwise the `(#N)` of the commit that added the file, or `pending`
#       before that commit lands.
#
# --root defaults to the repository holding this script.
set -u

usage() {
  awk 'NR == 1 { next } /^set -u/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() {
  printf 'fm-fork-decisions: %s\n' "$*" >&2
  exit 1
}

case "${1-}" in
  -h|--help) usage; exit 0 ;;
  check|patches) COMMAND=$1; shift ;;
  pr-check) COMMAND=pr_check; shift ;;
  *) usage >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE=
HEAD_REV=HEAD
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --base) [ "$COMMAND" = pr_check ] && [ $# -ge 2 ] || die "--base needs a revision and belongs to pr-check"; BASE=$2; shift 2 ;;
    --head) [ "$COMMAND" = pr_check ] && [ $# -ge 2 ] || die "--head needs a revision and belongs to pr-check"; HEAD_REV=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

INDEX="$ROOT/docs/fork-decisions.md"
DIR="$ROOT/docs/fork-decisions"
HEADER='| What | Files or functions | Upstream code touched | Status | Last checked sync |'
NAME_RE='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])-[a-z0-9]+(-[a-z0-9]+)*\.md$'

[ -f "$INDEX" ] || die "missing $INDEX"
[ -d "$DIR" ] || die "missing $DIR"

# Every entry in the records directory except hidden files (.DS_Store, editor
# swap files), oldest first.
records() {
  find "$DIR" -mindepth 1 -maxdepth 1 ! -name '.*' -print | LC_ALL=C sort
}

# The one record parser. Reports each format problem on stderr as
# docs/fork-decisions/<name>:<line>: <problem> and exits non-zero when it found
# one. With emit=1 it prints each fork-patch row as
# "| <date> | <pr> | <cells> |"; with emit=2 it prints each row as
# "<line>\t<status>\t<files cell>"; otherwise it prints the row count.
parse_record() {
  local path=$1 emit=$2 pr=${3-}
  local name=${path##*/}
  awk -v name="$name" -v date="${name:0:10}" -v header="$HEADER" -v emit="$emit" -v pr="$pr" '
    function fail(msg) { printf "docs/fork-decisions/%s:%d: %s\n", name, NR, msg > "/dev/stderr"; failed = 1 }
    { sub(/[ \t]+$/, "") }
    !started && (/^PR: / || /^$/) { next }
    !started { started = 1; if (index($0, date ": ") == 1) prose = 1 }
    /^\|/ {
      line = $0
      if (!table) {
        if (line != header) fail("a fork-patch table opens with: " header)
        table = 1; state = "separator"; next
      }
      if (state == "separator") {
        if (line !~ /^\|( --- \|)+$/) fail("the header is followed by its | --- | separator")
        state = "rows"; next
      }
      if (state == "done") { fail("a record holds one fork-patch table"); next }
      rowlines++
      inner = line
      gsub(/\\\|/, "\034", inner)
      sub(/^\|[ \t]*/, "", inner); sub(/[ \t]*\|$/, "", inner)
      n = split(inner, cells, /[ \t]*\|[ \t]*/)
      for (i = 1; i <= n; i++) gsub(/\034/, "\\|", cells[i])
      if (n != 5) { fail("a fork-patch row has 5 cells, found " n " (escape a literal pipe as \\|)"); next }
      if (cells[4] !~ /^(carried|upstreamed|conflicted)$/ && cells[4] !~ /superseded by /)
        fail("status is carried, upstreamed, conflicted, or a note saying what it is superseded by, not \"" cells[4] "\"")
      rows++
      if (emit == 2) print NR "\t" cells[4] "\t" cells[2]
      else if (emit) print "| " date " | " pr " | " cells[1] " | " cells[2] " | " cells[3] " | " cells[4] " | " cells[5] " |"
      next
    }
    table && state == "rows" { state = "done" }
    END {
      if (!prose && !table) fail("a record opens with \"" date ": \" (a decision) or holds a fork-patch table")
      if (table && !rowlines) fail("a fork-patch table needs at least one row")
      if (emit == 0) print rows + 0
      exit failed
    }' "$path"
}

# Whether a cited path names anything in the checkout: a plain path must
# exist, a glob must match, and one {a,b} brace group is tried per choice.
cited_path_exists() {
  local path=$1 head tail choices choice
  if [[ $path =~ ^([^{}]*)\{([^{}]*)\}([^{}]*)$ ]]; then
    head=${BASH_REMATCH[1]} choices=${BASH_REMATCH[2]} tail=${BASH_REMATCH[3]}
    while IFS= read -r choice; do
      cited_path_exists "$head$choice$tail" && return 0
    done < <(printf '%s\n' "$choices" | tr ',' '\n')
    return 1
  fi
  case "$path" in
    *[*?[]*) compgen -G "$ROOT/$path" >/dev/null ;;
    *) [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ] ;;
  esac
}

# Fail, naming the record line, for each path a carried or conflicted row
# cites that is missing. Only paths under a tracked top-level entry are
# checked, so a runtime path such as state/<file> or a function name is not.
check_cited_paths() {
  local path=$1 name=${1##*/} bad=0 line status files token rest top tops
  tops=$(git -C "$ROOT" ls-files 2>/dev/null | sed 's|/.*||' | LC_ALL=C sort -u)
  [ -n "$tops" ] || return 0
  while IFS=$'\t' read -r line status files; do
    case "$status" in carried|conflicted) ;; *) continue ;; esac
    rest=$files
    while [[ $rest =~ \`([^\`]+)\`(.*)$ ]]; do
      token=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
      [[ $rest =~ ^[[:space:]]*\(removed ]] && continue
      token=${token%%#*}
      top=${token%%/*}
      printf '%s\n' "$tops" | grep -qxF -- "$top" || continue
      cited_path_exists "$token" && continue
      # shellcheck disable=SC2016 # The backticks are literal Markdown.
      printf 'docs/fork-decisions/%s:%s: a %s row names %s, which is not in the repository; correct the path, or mark a file the patch deleted as `%s` (removed)\n' \
        "$name" "$line" "$status" "$token" "$token" >&2
      bad=1
    done
  done < <(parse_record "$path" 2 2>/dev/null)
  return "$bad"
}

command_check() {
  local bad=0 count=0 patches=0 path name rows
  if awk '/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]:/ || /^\|/ {
        printf "docs/fork-decisions.md:%d: a decision or fork-patch row belongs in its own file under docs/fork-decisions/, not the entry point\n", NR
        found = 1
      }
      END { exit found ? 0 : 1 }' "$INDEX" >&2; then
    bad=1
  fi
  while IFS= read -r path; do
    name=${path##*/}
    count=$((count + 1))
    if [ ! -f "$path" ] || ! printf '%s\n' "$name" | grep -Eq "$NAME_RE"; then
      printf 'docs/fork-decisions/%s: a record is a file named <YYYY-MM-DD>-<slug>.md with a real date and a lowercase slug\n' "$name" >&2
      bad=1
      continue
    fi
    rows=$(parse_record "$path" 0) || bad=1
    patches=$((patches + ${rows:-0}))
    check_cited_paths "$path" || bad=1
  done < <(records)
  [ "$bad" -eq 0 ] || exit 1
  printf 'fm-fork-decisions: ok records=%s patches=%s\n' "$count" "$patches"
}

# The PR a record names on its `PR:` line, else the PR that landed the commit
# adding it: a squash subject ending in (#N) or a GitHub merge commit's
# "Merge pull request #N". Renames are traced through the directory's own
# history with rename detection only, because --follow's copy detection
# mistakes one record for a copy of another that shares its table header.
record_pr() {
  local path=$1 pr subject
  pr=$(sed -n 's/^PR: //p' "$path" | head -n 1)
  if [ -n "$pr" ]; then
    printf '%s\n' "$pr"
    return
  fi
  subject=$(git -C "$ROOT" log --first-parent -M --format='%x01%s' --name-status \
    -- docs/fork-decisions 2>/dev/null |
    awk -F '\t' -v target="docs/fork-decisions/${path##*/}" '
      /^\001/ { subject = substr($0, 2); next }
      $1 ~ /^R/ && $3 == target { target = $2; next }
      $1 == "A" && $2 == target { print subject; exit }')
  pr=$(printf '%s\n' "$subject" | sed -n -e 's/.*(\(#[0-9][0-9]*\))$/\1/p' -e 's/^Merge pull request \(#[0-9][0-9]*\) .*/\1/p')
  printf '%s\n' "${pr:-pending}"
}

command_patches() {
  local path
  printf '| Date | PR | What | Files or functions | Upstream code touched | Status | Last checked sync |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- |\n'
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    grep -qF "$HEADER" "$path" || continue
    parse_record "$path" 1 "$(record_pr "$path")" || true
  done < <(records)
}

# The upstream sync commit: of the commits fork-patch rows name as their last
# checked sync, the newest one this checkout has.
upstream_sync_commit() {
  local value commit best="" best_time=0 time
  while IFS= read -r value; do
    commit=$(git -C "$ROOT" rev-parse --verify --quiet "$value^{commit}" 2>/dev/null) || continue
    time=$(git -C "$ROOT" show -s --format=%ct "$commit" 2>/dev/null) || continue
    if [ -z "$best" ] || [ "$time" -gt "$best_time" ]; then
      best=$commit best_time=$time
    fi
  done < <(command_patches | tail -n +3 | awk -F ' [|] ' '{ v = $NF; sub(/ [|]$/, "", v); gsub(/[ `]/, "", v); if (v ~ /^[0-9a-f]+$/) print v }' | LC_ALL=C sort -u)
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# upstream_owned <sync> - print each path read on stdin that exists at <sync>,
# except the records and their entry point, which are the fork's own. A
# function, because stock macOS Bash 3.2 cannot parse a case inside $(...).
upstream_owned() {
  local sync=$1 path
  while IFS= read -r path; do
    case "$path" in '' | docs/fork-decisions.md | docs/fork-decisions/*) continue ;; esac
    git -C "$ROOT" cat-file -e "$sync:$path" 2>/dev/null && printf '%s\n' "$path"
  done
  return 0
}

command_pr_check() {
  local sync base changed owned records
  [ -n "$BASE" ] || die "pr-check needs --base <rev>"
  git -C "$ROOT" rev-parse --verify --quiet "$HEAD_REV^{commit}" >/dev/null || die "cannot read --head $HEAD_REV"
  base=$(git -C "$ROOT" merge-base "$BASE" "$HEAD_REV" 2>/dev/null) \
    || die "cannot find a merge base of $BASE and $HEAD_REV; the check needs full history"
  sync=$(upstream_sync_commit) \
    || die "no fork-patch row names a last checked sync commit this checkout has; the check needs full history"
  changed=$(git -C "$ROOT" diff --name-only --no-renames "$base" "$HEAD_REV") || die "cannot diff $base..$HEAD_REV"
  # A deleted record documents nothing, so only added or edited ones count.
  records=$(git -C "$ROOT" diff --name-only --no-renames --diff-filter=AM "$base" "$HEAD_REV" -- docs/fork-decisions \
    | grep -E '^docs/fork-decisions/[^/]+\.md$' || true)
  owned=$(printf '%s\n' "$changed" | upstream_owned "$sync")
  if [ -n "$owned" ] && [ -z "$records" ]; then
    printf 'fm-fork-decisions: this change edits upstream-owned files (present at upstream sync %s) but adds or edits no docs/fork-decisions/ record; add a fork-patch record as docs/fork-decisions.md says:\n' "${sync:0:8}" >&2
    printf '%s\n' "$owned" | sed 's/^/  /' >&2
    exit 1
  fi
  printf 'fm-fork-decisions: pr-check ok upstream-owned=%s records=%s sync=%s\n' \
    "$(printf '%s' "$owned" | grep -c . || true)" "$(printf '%s' "$records" | grep -c . || true)" "${sync:0:8}"
}

"command_$COMMAND"
