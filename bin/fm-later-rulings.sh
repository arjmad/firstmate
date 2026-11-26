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
# Otherwise it is the earliest captain decision recorded on the task's backlog
# row: each resolution record bin/fm-captain-hold.sh wrote there through
# `answer` or `answer --release` (one per captain answer, the newest first)
# whose payload is "Captain decision:" gives one date. A record of mode
# answered or released whose header carries a well-formed `Resolved at:`
# stamp (that script's header owns the block) gives the stamp's day: the
# earlier of its UTC day and this host's local day, so a ruling the captain
# dated later the same local evening still counts. Any other record, such as
# one written before the stamp existed or a `repaired` one recorded after the
# fact, gives the first YYYY-MM-DD date of its decision text before the
# text's first blank line. The earliest is taken because a later answer, such
# as a release to start the queued ship, can postdate the approval of its
# text, and listing from too early only lists more. A record carrying
# "Reconciliation evidence:" is not the captain's word and gives no date. A
# row with no such record, or only records that give no date, has no approval
# date. The stamp dates when the answer was recorded, so an answer recorded
# well after he gave it dates the approval late.
#
# The rulings. Every dated item in this home's data/captain.md and, when
# present, data/captain-shared.md. An item is one list entry ("- ", "* " or
# "1. " at the line start) together with its indented continuation lines, or
# one other non-blank line. Its date is the latest full YYYY-MM-DD date in it
# that is not after tomorrow, so a ruling amended or relayed later counts from
# its newest date while a deadline such as "until 2027-01-15" does not; a short
# date such as "11-21" is not read. An item is listed when its
# date is on or after the approval date: a ruling carries no time of day, so
# one dated the approval day may still have come after it.
#
# Output, on stdout. When rulings are found, one header line naming the task,
# the approval date and where it came from (with the `Resolved at:` stamp when
# one gave it), then one line per item:
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

# Across the resolution records in a decoded row body, prints the earliest of
# their decision dates as `<YYYY-MM-DD> <stamp-or-prose>`, the stamp when that
# date came from a `Resolved at:` line (see the header). Only a record whose
# first payload label is "Captain decision:" gives a date, and only its own
# header, between the leader line and that label, can carry its stamp, so a
# stamp quoted in the captain's words or an older body below is not read. A
# heading outside any record or after a record's own label gives none.
approval_date_from_body() {
  perl -MPOSIX=strftime -MTime::Local=timegm -e '
    use strict; use warnings;
    my ($record, $labelled, $reading, $mode, $stamp) = (0, 0, 0, "", "");
    my ($earliest, $from) = ("", "");
    sub consider {
      my ($d, $source) = @_;
      ($earliest, $from) = ($d, $source) if $earliest eq "" || $d lt $earliest;
    }
    # The earlier of the stamp'"'"'s UTC day and its local day here; none when
    # the stamp names no real time.
    sub stamp_day {
      my ($y, $mo, $d, $h, $mi, $s) = $_[0] =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/ or return "";
      my $epoch = eval { timegm($s, $mi, $h, $d, $mo - 1, $y) };
      return "" unless defined $epoch;
      my $utc = strftime("%Y-%m-%d", gmtime $epoch);
      my $local = strftime("%Y-%m-%d", localtime $epoch);
      return $local lt $utc ? $local : $utc;
    }
    while (my $line = <STDIN>) {
      chomp $line;
      if ($line =~ /^Resolution recorded by fm-(captain|decision)-hold\.$/) {
        ($record, $labelled, $reading, $mode, $stamp) = (1, 0, 0, "", "");
        next;
      }
      if ($record && !$labelled) {
        if ($line =~ /^Resolution mode: (\S+)$/) { $mode = $1; next; }
        if ($line =~ /^Resolved at: (\S+)$/) { $stamp = $1; next; }
        if ($line =~ /^(Captain decision|Reconciliation evidence|Default release):$/) {
          $labelled = 1;
          $reading = 0;
          next unless $line eq "Captain decision:";
          my $day = ($mode eq "answered" || $mode eq "released") ? stamp_day($stamp) : "";
          if ($day ne "") { consider($day, "$stamp"); } else { $reading = 1; }
          next;
        }
      }
      if ($reading && $line eq "") { $reading = 0; next; }
      if ($reading && $line =~ /(\d{4}-\d\d-\d\d)/) { consider($1, "prose"); $reading = 0; }
    }
    print "$earliest $from\n" if $earliest ne "";
  '
}

SOURCE="--since"
if [ -z "$SINCE" ]; then
  SOURCE="the earliest captain decision on its backlog row"
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
  approval=$(printf '%s\n' "$body" | approval_date_from_body 2>/dev/null) || approval=
  SINCE=${approval%% *}
  [ -n "$SINCE" ] || say_empty "$ID records no dated captain approval; pass --since YYYY-MM-DD to check it"
  case "${approval#* }" in
    prose) ;;
    *) SOURCE="$SOURCE, recorded at ${approval#* }" ;;
  esac
fi

# A date after tomorrow is a deadline, not a ruling; tomorrow, not today, so
# a ruling dated in a time zone ahead of this host still counts.
LATEST_OK=$(perl -MPOSIX -e 'print strftime("%Y-%m-%d", localtime(time + 86400))' 2>/dev/null) || LATEST_OK=9999-12-31
LISTING=$(
  for file in "${FILES[@]}"; do
    awk -v since="$SINCE" -v until="$LATEST_OK" -v label="data/${file##*/}" '
      function flush(   rest, d, latest, text) {
        if (start == 0) return
        latest = ""
        rest = item
        while (match(rest, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
          d = substr(rest, RSTART, RLENGTH)
          if (d > latest && d <= until) latest = d
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

[ -n "$LISTING" ] || say_empty "no item in data/captain.md or data/captain-shared.md is dated on or after $ID's approval $SINCE"
COUNT=$(printf '%s\n' "$LISTING" | grep -c '^  ')
printf 'later-rulings: %s was approved %s (%s); %s captain ruling(s) are dated on or after it - re-read the approved text against each before merging:\n' \
  "$ID" "$SINCE" "$SOURCE" "$COUNT"
printf '%s\n' "$LISTING"
exit 0
