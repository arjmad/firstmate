#!/usr/bin/env bash
# fm-decision-sitting.sh - wake firstmate for the captain's decision sittings.
#
# Usage:
#   fm-decision-sitting.sh due
#   fm-decision-sitting.sh queued
#   fm-decision-sitting.sh slots
#
# The captain takes non-urgent calls at two decision sittings a day, 12:00 and
# 20:00 New York time, as one board (fork patch, docs/fork-decisions.md
# 2026-11-01). Which calls wait for a sitting, and how a sitting is run, is
# policy owned by .agents/skills/captain-hold-lifecycle/SKILL.md "Decision
# sittings"; this script owns only the clock and the count.
#
# A call waits for a sitting exactly when its own record says it may: an open
# task held for the captain whose hold is live (bin/fm-fleet-snapshot.sh's
# hold_bucket) and whose stored reason carries the `[reversible` kind prefix
# bin/fm-captain-hold.sh writes. An `arjun-only` hold, a hold with no kind, and
# a dated, blocked, or aged hold never count, so they never start a sitting.
# The count covers this home's backlog and every secondmate home the snapshot
# reads, because a secondmate's calls already reach this home through its
# parent channel; a secondmate home itself runs no sittings.
#
# `due` is the watcher's tick (bin/fm-watch.sh decision_sitting_tick). It finds
# the latest sitting at or before now in the sitting zone, so daylight saving
# follows the named zone rather than a fixed UTC offset. When that sitting is
# newer than the one recorded in state/.last-decision-sitting and at least one
# call is waiting, it queues one durable `check:` wake keyed
# `decision-sitting:<epoch>` and prints its payload:
#   check: decision sitting <YYYY-MM-DD HH:MM> <zone>: <n> call(s) waiting ...
# A sitting with nothing waiting records itself and prints nothing, so it
# produces no captain-facing output. The marker write and the append share the
# wake-queue lock, and a key still queued gets no second row. A missing marker
# only starts the cadence (the next sitting is the first), and a watcher that
# was down across several sittings fires once, for the latest. A snapshot read
# that fails exits 1 and leaves the marker alone, so the next tick retries.
# In a secondmate home `due` does nothing.
#
# `queued` prints the waiting call ids, one per line (`<mate-id>/<task-id>` for
# a secondmate's), and is read-only apart from the snapshot's own cache refresh.
# `slots` prints the `last` and `next` sitting as `<label> <epoch> <local time>`.
#
# FM_DECISION_SITTING_TIMES (default "12:00 20:00", HH:MM in the zone) and
# FM_DECISION_SITTING_ZONE (default America/New_York) change the schedule;
# FM_DECISION_SITTING_NOW (epoch seconds) fixes the clock and
# FM_DECISION_SITTING_SNAPSHOT a snapshot JSON file, for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-parent-channel-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

ZONE=${FM_DECISION_SITTING_ZONE:-America/New_York}
TIMES=${FM_DECISION_SITTING_TIMES:-12:00 20:00}
MARKER="$STATE/.last-decision-sitting"

usage() {
  sed -n '2,45{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-decision-sitting: %s\n' "$1" >&2
  exit 1
}

now_epoch() {
  local now=${FM_DECISION_SITTING_NOW:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) die "FM_DECISION_SITTING_NOW must be epoch seconds" ;; esac
  printf '%s\n' "$now"
}

# Epoch of <YYYY-MM-DD> <HH:MM> as wall-clock time in the sitting zone.
zone_epoch() {  # <date> <HH:MM>
  TZ=$ZONE date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2:00" +%s 2>/dev/null && return 0
  TZ=$ZONE date -d "$1 $2:00" +%s 2>/dev/null && return 0
  return 1
}

# <epoch> rendered in the sitting zone with <format>.
zone_format() {  # <epoch> <format>
  TZ=$ZONE date -r "$1" "+$2" 2>/dev/null && return 0
  TZ=$ZONE date -d "@$1" "+$2" 2>/dev/null && return 0
  return 1
}

# A zone the system cannot resolve would silently read as UTC, so refuse it.
validate_zone() {
  local dir
  case "$ZONE" in ''|/*|*..*) die "FM_DECISION_SITTING_ZONE is not a zone name: $ZONE" ;; esac
  for dir in "${TZDIR:-}" /usr/share/zoneinfo /var/db/timezone/zoneinfo /usr/lib/zoneinfo; do
    [ -n "$dir" ] && [ -f "$dir/$ZONE" ] && return 0
  done
  die "the time zone $ZONE is not installed (no zoneinfo file), so sitting times cannot be resolved"
}

validated_times() {
  local t
  for t in $TIMES; do
    case "$t" in
      [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) printf '%s\n' "$t" ;;
      *) die "FM_DECISION_SITTING_TIMES holds a time that is not HH:MM: $t" ;;
    esac
  done
}

# Every sitting on the zone day before, of, and after <epoch>, ascending. The
# neighbouring days come from the zone's own midnight, so a 23- or 25-hour day
# never skips or repeats a date.
sitting_epochs() {  # <epoch>
  local now=$1 today midnight day t times epochs=''
  validate_zone
  times=$(validated_times) || exit 1
  [ -n "$times" ] || die "FM_DECISION_SITTING_TIMES names no sitting"
  today=$(zone_format "$now" %Y-%m-%d) || die "cannot read the date in $ZONE"
  midnight=$(zone_epoch "$today" 00:00) || die "cannot resolve midnight in $ZONE"
  for day in \
    "$(zone_format $((midnight - 3600)) %Y-%m-%d)" \
    "$today" \
    "$(zone_format $((midnight + 30 * 3600)) %Y-%m-%d)"; do
    [ -n "$day" ] || die "cannot read a neighbouring date in $ZONE"
    for t in $times; do
      t=$(zone_epoch "$day" "$t") || die "cannot resolve $day $t in $ZONE"
      epochs="$epochs$t"$'\n'
    done
  done
  printf '%s' "$epochs" | sort -n
}

last_sitting() {  # <epoch>
  local now=$1 slot epochs last=''
  epochs=$(sitting_epochs "$now") || exit 1
  for slot in $epochs; do
    [ "$slot" -le "$now" ] && last=$slot
  done
  [ -n "$last" ] || die "no sitting found at or before $now"
  printf '%s\n' "$last"
}

next_sitting() {  # <epoch>
  local now=$1 slot epochs
  epochs=$(sitting_epochs "$now") || exit 1
  for slot in $epochs; do
    [ "$slot" -gt "$now" ] && { printf '%s\n' "$slot"; return 0; }
  done
  die "no sitting found after $now"
}

sitting_label() {  # <epoch>
  printf '%s %s\n' "$(zone_format "$1" '%Y-%m-%d %H:%M')" "$ZONE"
}

snapshot_json() {
  if [ -n "${FM_DECISION_SITTING_SNAPSHOT:-}" ]; then
    cat -- "$FM_DECISION_SITTING_SNAPSHOT"
    return
  fi
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
}

queued_ids() {
  local json
  command -v jq >/dev/null 2>&1 || die "jq is required to count waiting calls"
  json=$(snapshot_json 2>/dev/null) || die "the fleet snapshot could not be read"
  printf '%s\n' "$json" | jq -r '
    def waits: (. // "") | tostring | startswith("[reversible");
    ([.backlog.records[]?
       | select(.structured and .hold_kind == "captain" and .state != "done"
                and .hold_bucket == "live" and (.hold_reason | waits))
       | .id]
     + [(.secondmate_current.records // [])[] as $m
        | $m.decisions_open[]?
        | select(.source == "backlog" and .verb == "captain-hold"
                 and .hold_bucket == "live" and (.reason | waits))
        | "\($m.id)/\(.id)"])
    | unique | .[]' 2>/dev/null || die "the fleet snapshot could not be parsed"
}

load_wake_lib() {
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"
}

record_sitting() {  # <epoch>
  printf '%s\n' "$1" > "$MARKER.tmp" && mv -f "$MARKER.tmp" "$MARKER"
}

cmd_due() {
  local now slot recorded ids count key payload queued
  [ "$#" -eq 0 ] || die "usage: fm-decision-sitting.sh due"
  if fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1; then
    return 0
  fi
  now=$(now_epoch)
  slot=$(last_sitting "$now") || exit 1
  if [ ! -e "$MARKER" ]; then
    record_sitting "$slot" || die "cannot record the sitting under $MARKER"
    return 0
  fi
  recorded=$(cat "$MARKER" 2>/dev/null)
  case "$recorded" in ''|*[!0-9]*) recorded=0 ;; esac
  [ "$recorded" -lt "$slot" ] || return 0
  ids=$(queued_ids) || exit 1
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    record_sitting "$slot" || die "cannot record the sitting under $MARKER"
    return 0
  fi
  key="decision-sitting:$slot"
  payload="check: decision sitting $(sitting_label "$slot"): $count call(s) waiting for the captain (bin/fm-decision-sitting.sh queued)"
  load_wake_lib || die "cannot load the wake library"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || die "cannot take the wake-queue lock"
  queued=$(fm_wake_queued_keys_locked check)
  if printf '%s\n' "$queued" | grep -Fxq "$key"; then
    record_sitting "$slot" || true
  elif fm_wake_append_locked check "$key" "$payload"; then
    record_sitting "$slot" \
      || printf 'fm-decision-sitting: woke for %s but could not record it under %s\n' "$key" "$MARKER" >&2
    printf '%s\n' "$payload"
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

cmd_queued() {
  [ "$#" -eq 0 ] || die "usage: fm-decision-sitting.sh queued"
  queued_ids
}

cmd_slots() {
  local now last next
  [ "$#" -eq 0 ] || die "usage: fm-decision-sitting.sh slots"
  now=$(now_epoch)
  last=$(last_sitting "$now") || exit 1
  next=$(next_sitting "$now") || exit 1
  printf 'last %s %s\n' "$last" "$(sitting_label "$last")"
  printf 'next %s %s\n' "$next" "$(sitting_label "$next")"
}

case "${1:-}" in
  due) shift; cmd_due "$@" ;;
  queued) shift; cmd_queued "$@" ;;
  slots) shift; cmd_slots "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
