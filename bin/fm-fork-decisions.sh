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
#       Prints `fm-fork-decisions: ok records=<n> patches=<n>` on success.
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
  *) usage >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT=$2; shift 2 ;;
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
# "| <date> | <pr> | <cells> |"; otherwise it prints the row count.
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
      if (emit) print "| " date " | " pr " | " cells[1] " | " cells[2] " | " cells[3] " | " cells[4] " | " cells[5] " |"
      next
    }
    table && state == "rows" { state = "done" }
    END {
      if (!prose && !table) fail("a record opens with \"" date ": \" (a decision) or holds a fork-patch table")
      if (table && !rowlines) fail("a fork-patch table needs at least one row")
      if (!emit) print rows + 0
      exit failed
    }' "$path"
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

"command_$COMMAND"
