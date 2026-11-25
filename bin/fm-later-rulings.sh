#!/usr/bin/env bash
# fm-later-rulings.sh - list the captain rulings dated on or after a ship's
# approval, so the landing firstmate re-reads the approved text against them
# before the merge (fork patch, docs/fork-decisions/2026-11-25-later-rulings-at-landing.md).
#
# Usage:
#   fm-later-rulings.sh <task-id> [--since YYYY-MM-DD] [--found-only]
#   fm-later-rulings.sh -h | --help
#
# A ship can carry text the captain approved days before it lands, and he may
# rule against that text in between. This script is a read-only, advisory
# listing: it never compares the text itself, never blocks anything, and exits
# 0 whatever it finds or cannot read; only a malformed argument exits 2.
#
# The approval date. --since gives it directly, for an approval recorded
# somewhere other than the task's backlog row, such as an audit's picks.
# Otherwise it is the first YYYY-MM-DD date in the "Captain decision:" text of
# the newest resolution record bin/fm-captain-hold.sh wrote into the task's
# backlog row (records are prepended, so the first one in the body is the
# newest), the record its `answer` or `answer --release` leaves when the
# captain approves or releases the work. A "Reconciliation evidence:" record is
# not the captain's word and is never read as an approval. A row with no such
# record, or a decision text with no date, has no approval date.
#
# The rulings. Every dated item in this home's data/captain.md and, when
# present, data/captain-shared.md. An item is one list entry ("- ", "* " or
# "1. " at the line start) together with its indented continuation lines, or
# one other non-blank line. Its date is the latest full YYYY-MM-DD date
# anywhere in it, so a ruling amended or relayed later counts from its newest
# date; a short date such as "11-21" is not read. An item is listed when its
# date is on or after the approval date: a ruling carries no time of day, so
# one dated the approval day may still have come after it.
#
# Output, on stdout. When rulings are found, one header line naming the task,
# the approval date and where it came from, then one line per item:
#   <file>:<first line> <date> <the item, whitespace collapsed, cut to 200 characters>
# Otherwise one line saying why nothing was listed: no captain file, no
# approval date, an unreadable backlog row, or no later ruling. --found-only
# drops that line, so a caller such as bin/fm-pr-check.sh or bin/fm-pr-merge.sh
# prints only a real finding.
#
# Environment: FM_HOME selects the home; FM_DATA_OVERRIDE its data directory.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

ID=
SINCE=
FOUND_ONLY=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since)
      [ "$#" -ge 2 ] || { echo "error: --since needs a YYYY-MM-DD date" >&2; exit 2; }
      SINCE=$2
      shift 2
      ;;
    --found-only) FOUND_ONLY=true; shift ;;
    -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "error: one task id only" >&2; exit 2; }
      ID=$1
      shift
      ;;
  esac
done
[ -n "$ID" ] || { usage >&2; exit 2; }
case "$ID" in
  *[!A-Za-z0-9._-]*|.*) echo "error: invalid task id: $ID" >&2; exit 2 ;;
esac
if [ -n "$SINCE" ] && ! printf '%s' "$SINCE" | grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
  echo "error: --since takes a YYYY-MM-DD date, not: $SINCE" >&2
  exit 2
fi

say_empty() {  # <line>
  [ "$FOUND_ONLY" = true ] || printf 'later-rulings: %s\n' "$1"
  exit 0
}

FILES=()
for name in captain.md captain-shared.md; do
  [ -f "$DATA/$name" ] && [ -r "$DATA/$name" ] && FILES+=("$DATA/$name")
done
[ "${#FILES[@]}" -gt 0 ] || say_empty "no data/captain.md or data/captain-shared.md in this home"

# The newest "Captain decision:" text in a decoded row body, up to the blank
# line that ends its block, prints its first full date.
approval_date_from_body() {
  awk '
    !found && $0 == "Captain decision:" { found = 1; next }
    found && $0 == "" { exit }
    found && match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
      print substr($0, RSTART, RLENGTH); exit
    }
  '
}

SOURCE="--since"
if [ -z "$SINCE" ]; then
  SOURCE="the newest captain-hold resolution on its backlog row"
  show=
  if [ -f "$SCRIPT_DIR/fm-tasks-axi-lib.sh" ] && [ -f "$SCRIPT_DIR/fm-backlog-transition-lib.sh" ]; then
    # shellcheck source=bin/fm-tasks-axi-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
    # shellcheck source=bin/fm-backlog-transition-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
    if data_abs=$(fm_backlog_data_absolute "$DATA" 2>/dev/null); then
      show=$(fm_backlog_row_show "$data_abs" "$ID" --full 2>/dev/null) || show=
    fi
  fi
  [ -n "$show" ] || say_empty "could not read the backlog row of $ID; pass --since YYYY-MM-DD to check its approval"
  # The shown body is one JSON-encoded string with \n escapes.
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | head -n 1 | perl -MJSON::PP -e '
    local $/;
    my $raw = <STDIN>;
    $raw =~ s/\s+\z//;
    my $value = $raw =~ /\A"/ ? JSON::PP->new->utf8->allow_nonref->decode($raw) : $raw;
    binmode STDOUT, ":raw";
    utf8::encode($value) if utf8::is_utf8($value);
    print $value, "\n";
  ' 2>/dev/null) || body=
  SINCE=$(printf '%s\n' "$body" | approval_date_from_body)
  [ -n "$SINCE" ] || say_empty "$ID records no dated captain approval; pass --since YYYY-MM-DD to check it"
fi

LISTING=$(
  for file in "${FILES[@]}"; do
    awk -v since="$SINCE" -v label="data/${file##*/}" '
      function flush(   rest, d, latest, text) {
        if (start == 0) return
        latest = ""
        rest = item
        while (match(rest, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          d = substr(rest, RSTART, RLENGTH)
          if (d > latest) latest = d
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (latest != "" && latest >= since) {
          text = item
          gsub(/[[:space:]]+/, " ", text)
          sub(/^ /, "", text)
          if (length(text) > 200) text = substr(text, 1, 197) "..."
          printf "  %s:%d %s %s\n", label, start, latest, text
        }
        start = 0
        item = ""
      }
      /^[[:space:]]*$/ { flush(); next }
      /^[[:space:]]+[^[:space:]]/ && start != 0 { item = item " " $0; next }
      /^([-*]|[0-9]+\.)[[:space:]]/ { flush(); start = NR; item = $0; next }
      { flush(); start = NR; item = $0; flush() }
      END { flush() }
    ' "$file" 2>/dev/null || true
  done
)

[ -n "$LISTING" ] || say_empty "no captain ruling dated on or after $ID's approval $SINCE"
COUNT=$(printf '%s\n' "$LISTING" | grep -c '^  ')
printf 'later-rulings: %s was approved %s (%s); %s captain ruling(s) are dated on or after it - re-read the approved text against each before merging:\n' \
  "$ID" "$SINCE" "$SOURCE" "$COUNT"
printf '%s\n' "$LISTING"
exit 0
