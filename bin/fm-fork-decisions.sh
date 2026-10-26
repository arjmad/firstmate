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
NAME_RE='^[0-9]{4}-[0-1][0-9]-[0-3][0-9]-[a-z0-9]+(-[a-z0-9]+)*\.md$'

[ -f "$INDEX" ] || die "missing $INDEX"
[ -d "$DIR" ] || die "missing $DIR"

records() {
  find "$DIR" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort
}

command_check() {
  local bad=0 count=0 patches=0 path name date rows
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
      printf 'docs/fork-decisions/%s: a record is a file named <YYYY-MM-DD>-<slug>.md (lowercase slug)\n' "$name" >&2
      bad=1
      continue
    fi
    date=${name:0:10}
    rows=$(awk -v name="$name" -v date="$date" -v header="$HEADER" '
      function fail(msg) { printf "docs/fork-decisions/%s:%d: %s\n", name, NR, msg > "/dev/stderr"; failed = 1 }
      NR == 1 && index($0, date ": ") == 1 { prose = 1 }
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
        n = split(substr(line, 3, length(line) - 4), cells, / \| /)
        if (n != 5) { fail("a fork-patch row has 5 cells, found " n); next }
        if (cells[4] == "") fail("a fork-patch row names its status")
        rows++
        next
      }
      table && state == "rows" { state = "done" }
      END {
        if (!prose && !table) fail("a record opens with \"" date ": \" (a decision) or holds a fork-patch table")
        if (table && !rows) fail("a fork-patch table needs at least one row")
        print rows + 0
        exit failed
      }' "$path") || bad=1
    patches=$((patches + ${rows:-0}))
  done < <(records)
  [ "$bad" -eq 0 ] || exit 1
  printf 'fm-fork-decisions: ok records=%s patches=%s\n' "$count" "$patches"
}

# The PR a record names on its `PR:` line, else the one whose squash commit
# added it.
record_pr() {
  local path=$1 pr subject
  pr=$(sed -n 's/^PR: //p' "$path" | head -n 1)
  if [ -n "$pr" ]; then
    printf '%s\n' "$pr"
    return
  fi
  subject=$(git -C "$ROOT" log --diff-filter=A --format=%s -- "docs/fork-decisions/${path##*/}" 2>/dev/null | tail -n 1)
  pr=$(printf '%s\n' "$subject" | sed -n 's/.*(\(#[0-9][0-9]*\))$/\1/p')
  printf '%s\n' "${pr:-pending}"
}

command_patches() {
  local path name pr
  printf '| Date | PR | What | Files or functions | Upstream code touched | Status | Last checked sync |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- |\n'
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    name=${path##*/}
    grep -qxF "$HEADER" "$path" || continue
    pr=$(record_pr "$path")
    awk -v date="${name:0:10}" -v pr="$pr" -v header="$HEADER" '
      $0 == header { table = 1; skip = 1; next }
      table && skip { skip = 0; next }
      table && /^\|/ { print "| " date " | " pr " " $0; next }
      table { exit }' "$path"
  done < <(records)
}

"command_$COMMAND"
