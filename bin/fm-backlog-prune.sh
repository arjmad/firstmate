#!/usr/bin/env bash
# fm-backlog-prune.sh - the weekly backlog prune: when its card is due, what
# exactly it offered, and the drops and snoozes the captain's answer orders.
#
# Usage:
#   fm-backlog-prune.sh schedule
#   fm-backlog-prune.sh status
#   fm-backlog-prune.sh offer <slot> <id>...
#   fm-backlog-prune.sh apply <key> drop-all
#   fm-backlog-prune.sh apply <key> drop-picked <n>[,<n>...]
#   fm-backlog-prune.sh apply <key> keep
#
# Which rows the card proposes is bin/fm-backlog-prune-lib.sh's rule; this
# command owns the week, the offer, and the drop.
#
# THE WEEK. The card's slot opens every Monday at 06:00 in the host's local
# time. The card is due while the current slot is open: no answer was recorded
# since the slot opened, and any snooze has run out (its date is today or
# earlier, local). Any answer - a drop or a keep - closes the slot until next
# Monday; `keep` also snoozes the card for seven days, so a keep later in the
# week brings the card back a week later rather than next Monday.
#
# schedule   Print {schema, now, today, slot, slot_opens, open, answered_at,
#            answer, snoozed_until} as JSON: the current slot (its Monday,
#            YYYY-MM-DD), when it opened (UTC), and whether it is open. It
#            reads only this command's own record.
# status     Print the schedule plus `candidates` (bin/fm-backlog-prune-lib.sh
#            over this home's backlog, oldest touch first), `age_days` (the
#            threshold) and `due` (open and at least one candidate), as JSON.
#            The bearings snapshot projects the same rule itself under
#            `--fields board`; this is the standalone read.
# offer      Record exactly which rows a board card shows, in order, and print
#            its key: prune.<slot>.<8 hex digits of the ids' sha256>. The slot
#            must be the current one and every id a backlog-id slug.
#            bin/fm-bearings-board.sh build calls this for the payload's prune
#            card, so an answer always names one recorded list even when a
#            rebuild later shows a different one. The newest 8 offers are kept.
# apply      Carry out one answer to the offer <key> names:
#              drop-all       every row the card listed;
#              drop-picked    the rows at those 1-based positions in its list;
#              keep           nothing dropped, the card snoozed seven days.
#            Each row to drop is re-checked against the rule in the backlog as
#            it is now, so a row touched, held, claimed, or started since the
#            card was built is kept and named. Every other one is closed through
#            bin/fm-tasks-axi.sh with the note line
#              dropped by <captain>'s prune, <YYYY-MM-DD>
#            (UTC date; the captain is the first name in config/captain-name,
#            else "the captain"). Nothing is deleted: `fm-tasks-axi.sh reopen`
#            brings a row back. Output is one line per row,
#              dropped: <id>
#              skipped: <id> (<why it no longer qualifies>)
#              failed: <id>
#            then `answered: <slot> <answer>` once the answer is recorded, plus
#            `snoozed-until: <date>` for keep. An answer to an earlier week's
#            card (its offer is still kept) drops what it names but records
#            nothing, so it never closes or snoozes the current week's card. Re-running an apply is safe: a
#            row already dropped is skipped as no longer queued. Exit 1 when
#            any close failed (the answer is still recorded, so the card does
#            not come back for rows that did drop), 2 for a refused argument or
#            an unknown key.
#
# Records live under state/backlog-prune/: schedule.json (the last answer) and
# offers/<key>.json. FM_PRUNE_NOW (epoch seconds) fixes the clock and TZ the
# local zone, for tests; FM_BACKLOG_PRUNE_AGE_DAYS sets the threshold
# (bin/fm-backlog-prune-lib.sh parses it, and any other value is refused).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-backlog-prune-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-prune-lib.sh"

PRUNE_DIR="$STATE/backlog-prune"
SCHEDULE_FILE="$PRUNE_DIR/schedule.json"
OFFER_DIR="$PRUNE_DIR/offers"
OFFERS_KEPT=8
NOW=${FM_PRUNE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {  # <status> <message>
  printf 'fm-backlog-prune: %s\n' "$2" >&2
  exit "$1"
}

command -v jq >/dev/null 2>&1 || fail 1 "jq is required"
AGE_DAYS=$(fm_backlog_prune_age_days) \
  || fail 2 "FM_BACKLOG_PRUNE_AGE_DAYS must be a positive whole number of days: ${FM_BACKLOG_PRUNE_AGE_DAYS-}"

# The current weekly slot from the local clock: its Monday's date and the
# epoch of that Monday 06:00, the most recent one at or before now.
slot_fields() {
  perl -MPOSIX=mktime,strftime -e '
    my $now = $ARGV[0];
    my @t = localtime($now);
    my $back = ($t[6] + 6) % 7;
    my $open = mktime(0, 0, 6, $t[3] - $back, $t[4], $t[5], 0, 0, -1);
    $open = mktime(0, 0, 6, $t[3] - $back - 7, $t[4], $t[5], 0, 0, -1) if $open > $now;
    my $next = mktime(0, 0, 0, $t[3] + 7, $t[4], $t[5], 0, 0, -1);
    print join("\t", strftime("%Y-%m-%d", localtime($open)), $open,
      strftime("%Y-%m-%d", @t), strftime("%Y-%m-%d", localtime($next))), "\n";
  ' "$NOW"
}

schedule_json() {
  local fields slot open today week record='{}'
  fields=$(slot_fields) || fail 1 "cannot compute the weekly slot"
  IFS=$'\t' read -r slot open today week <<< "$fields"
  if [ -f "$SCHEDULE_FILE" ]; then
    record=$(jq -c 'if type == "object" then . else {} end' "$SCHEDULE_FILE" 2>/dev/null) \
      || fail 1 "unreadable schedule record: $SCHEDULE_FILE"
  fi
  jq -n --argjson rec "$record" --arg slot "$slot" --argjson open "$open" \
    --arg today "$today" --argjson now "$NOW" '
    ($rec.answered_at | if type == "number" then . else null end) as $answered
    | ($rec.snoozed_until | if type == "string" then . else null end) as $snooze
    | {schema:"fm-backlog-prune-schedule.v1", now:($now | todate), today:$today,
       slot:$slot, slot_opens:($open | todate),
       open:((($answered // 0) < $open) and ($snooze == null or $snooze <= $today)),
       answered_at:(if $answered == null then null else ($answered | todate) end),
       answer:($rec.answer // null), snoozed_until:$snooze}'
}

backlog_input() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input
}

captain_name() {
  local name=''
  if [ -f "$CONFIG/captain-name" ]; then
    name=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' "$CONFIG/captain-name" | head -1)
  fi
  printf '%s\n' "${name:-the captain}"
}

utc_today() { jq -nr --argjson now "$NOW" '$now | strftime("%Y-%m-%d")'; }

command_status() {
  local schedule input
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  schedule=$(schedule_json) || exit 1
  input=$(backlog_input) || fail 1 "cannot read this home's backlog"
  printf '%s' "$input" | jq --argjson schedule "$schedule" --arg today "$(utc_today)" \
    --argjson age "$AGE_DAYS" "$FM_PRUNE_JQ_DEFS"'
    ([.tasks[]? | select(.kind != "secondmate") | .id]) as $live
    | prune_candidates(.backlog.records; $today; $age; $live) as $c
    | $schedule + {schema:"fm-backlog-prune-status.v1", age_days:$age,
        due:($schedule.open and ($c | length) > 0), candidates:$c}'
}

offer_key() {  # <slot> <id>...
  local slot=$1 digest
  shift
  digest=$(printf '%s\n' "$@" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{ print substr($1, 1, 8) }')
  [ "${#digest}" -eq 8 ] || return 1
  printf 'prune.%s.%s\n' "$slot" "$digest"
}

command_offer() {
  local slot current key id tmp
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  slot=$1
  shift
  current=$(schedule_json) || exit 1
  current=$(printf '%s' "$current" | jq -r '.slot') || fail 1 "cannot read the weekly slot"
  [ "$slot" = "$current" ] || fail 2 "offer slot $slot is not the current slot $current"
  for id in "$@"; do
    printf '%s' "$id" | grep -Eq '^[A-Za-z0-9._-]{1,128}$' || fail 2 "not a backlog id: $id"
  done
  [ "$(printf '%s\n' "$@" | sort | uniq -d | wc -l | tr -d ' ')" = 0 ] || fail 2 "an offer lists each row once"
  key=$(offer_key "$slot" "$@") || fail 1 "cannot digest the offer (shasum or sha256sum is required)"
  (umask 077; mkdir -p "$OFFER_DIR") || fail 1 "cannot create $OFFER_DIR"
  tmp=$(umask 077; mktemp "$OFFER_DIR/.offer.XXXXXX") || fail 1 "cannot stage the offer"
  if ! jq -n --arg key "$key" --arg slot "$slot" --argjson now "$NOW" '
      {schema:"fm-backlog-prune-offer.v1", key:$key, slot:$slot, recorded:($now | todate),
       ids:$ARGS.positional}' --args "$@" > "$tmp" || ! mv -f -- "$tmp" "$OFFER_DIR/$key.json"; then
    rm -f -- "$tmp"
    fail 1 "cannot record the offer"
  fi
  # Keep only the newest offers; an answer to an older board card refuses.
  # shellcheck disable=SC2012 # offer names are prune.<date>.<hex>.json
  ls -1t "$OFFER_DIR" 2>/dev/null | tail -n +$((OFFERS_KEPT + 1)) \
    | while IFS= read -r old; do
        case "$old" in prune.*.json) rm -f -- "${OFFER_DIR:?}/$old" ;; esac
      done
  printf '%s\n' "$key"
}

record_answer() {  # <slot> <answer> <snoozed-until-or-empty>
  local tmp
  (umask 077; mkdir -p "$PRUNE_DIR") || return 1
  tmp=$(umask 077; mktemp "$PRUNE_DIR/.schedule.XXXXXX") || return 1
  if ! jq -n --argjson now "$NOW" --arg slot "$1" --arg answer "$2" --arg snooze "$3" '
      {schema:"fm-backlog-prune-schedule.v1", answered_at:$now, slot:$slot, answer:$answer,
       snoozed_until:(if $snooze == "" then null else $snooze end)}' > "$tmp" \
    || ! mv -f -- "$tmp" "$SCHEDULE_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Record an answer to the current week's card, which closes its slot (and
# snoozes it for keep). An answer to an earlier week's card still drops what
# it names, but leaves this week's card exactly as it was.
close_slot() {  # <offer-slot> <answer> <snoozed-until-or-empty>
  local current
  current=$(schedule_json) || exit 1
  current=$(printf '%s' "$current" | jq -r '.slot') || fail 1 "cannot read the weekly slot"
  if [ "$1" != "$current" ]; then
    printf "answered: %s %s (an earlier week's card; this week's card is unchanged)\n" "$1" "$2"
    return 0
  fi
  record_answer "$1" "$2" "$3" || fail 1 "cannot record the answer"
  printf 'answered: %s %s\n' "$1" "$2"
  [ -z "$3" ] || printf 'snoozed-until: %s\n' "$3"
}

command_apply() {
  local key=${1-} answer=${2-} picked=${3-} offer slot list input verdicts note rc=0 id why fields week
  local -a ids
  case "$answer" in
    drop-all|keep) [ "$#" -eq 2 ] || { usage >&2; exit 2; } ;;
    drop-picked)
      [ "$#" -eq 3 ] || { usage >&2; exit 2; }
      printf '%s' "$picked" | grep -Eq '^[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})*$' \
        || fail 2 "drop-picked takes 1-based positions such as 1,4,7: $picked" ;;
    *) usage >&2; exit 2 ;;
  esac
  printf '%s' "$key" | grep -Eq '^prune\.[0-9]{4}-[0-9]{2}-[0-9]{2}\.[0-9a-f]{8}$' || fail 2 "not a prune key: $key"
  offer="$OFFER_DIR/$key.json"
  [ -f "$offer" ] || fail 2 "no recorded offer for $key (offers older than the newest $OFFERS_KEPT are not kept)"
  slot=$(jq -er '.slot | strings' "$offer") || fail 1 "unreadable offer: $offer"

  if [ "$answer" = keep ]; then
    fields=$(slot_fields) || fail 1 "cannot compute the weekly slot"
    week=$(printf '%s' "$fields" | cut -f4)
    close_slot "$slot" keep "$week"
    return 0
  fi

  if [ "$answer" = drop-all ]; then
    list=$(jq -r '.ids[]' "$offer") || fail 1 "unreadable offer: $offer"
  else
    list=$(jq -r --arg picked "$picked" '
      .ids as $ids | ($picked | split(",") | map(tonumber) | unique) as $at
      | if any($at[]; . > ($ids | length)) then error("position past the end of the offer (\($ids | length) rows)")
        else $at[] | $ids[. - 1] end' "$offer") || fail 2 "cannot read those positions from $key"
  fi
  ids=()
  while IFS= read -r id; do [ -z "$id" ] || ids+=("$id"); done <<< "$list"

  input=$(backlog_input) || fail 1 "cannot read this home's backlog"
  verdicts=$(printf '%s' "$input" | jq -r --arg today "$(utc_today)" --argjson age "$AGE_DAYS" \
    --args "$FM_PRUNE_JQ_DEFS"'
    ([.tasks[]? | select(.kind != "secondmate") | .id]) as $live
    | .backlog.records as $records
    | $ARGS.positional[] as $id
    | ([$records[] | select(.structured == true and .id == $id)] | last) as $row
    | prune_depended_ids($records) as $depended
    | "\($id)\t\(if $row == null then "not in the backlog" else ($row | prune_refusal($today; $age; $live; $depended) // "") end)"
    ' "${ids[@]}") || fail 1 "cannot check the rows against the backlog"
  note="dropped by $(captain_name)'s prune, $(utc_today)"
  while IFS=$'\t' read -r id why; do
    [ -n "$id" ] || continue
    if [ -n "$why" ]; then
      printf 'skipped: %s (%s)\n' "$id" "$why"
    elif "$SCRIPT_DIR/fm-tasks-axi.sh" 'done' "$id" --note "$note" >/dev/null 2>&1; then
      printf 'dropped: %s\n' "$id"
    else
      printf 'failed: %s\n' "$id"
      rc=1
    fi
  done <<< "$verdicts"
  close_slot "$slot" "$answer" ''
  return "$rc"
}

case "${1-}" in
  schedule) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; schedule_json ;;
  status) shift; command_status "$@" ;;
  offer) shift; command_offer "$@" ;;
  apply) shift; command_apply "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
