#!/usr/bin/env bash
# fm-decision-sitting.sh - wake firstmate for the captain's decision sittings.
#
# Usage:
#   fm-decision-sitting.sh due
#   fm-decision-sitting.sh queued
#   fm-decision-sitting.sh slots
#   fm-decision-sitting.sh waiting
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
# `decision-sitting:<epoch>` and prints `<key>\t<payload>`, the payload being
#   check: decision sitting <YYYY-MM-DD HH:MM> <zone>: <n> call(s) waiting ...
# The watcher wakes with that payload only while its key is still queued, so a
# sitting already drained and acknowledged never wakes a second time.
# A sitting with nothing waiting records itself and prints nothing, so it
# produces no captain-facing output. The marker write and the append share the
# wake-queue lock, which also re-reads the marker so two overlapping runs wake
# once, and a key still queued gets no second row. A missing marker only
# starts the cadence (the next sitting is the first). A sitting first seen more
# than FM_DECISION_SITTING_GRACE seconds (default 3600) after its time, because
# no watcher ran across it, is recorded without a wake, so its calls, and any
# held after it, wait for the next sitting rather than arriving off schedule.
# A snapshot read
# that fails exits 1 and leaves the marker alone, so the next tick retries; the
# first failure for a sitting also queues one `check: decision sitting <time>
# could not count the waiting calls ...` wake keyed
# `decision-sitting-failed:<epoch>` (recorded in
# state/.last-decision-sitting-failed), so a sitting is never missed silently.
# In a secondmate home `due` does nothing.
#
# `waiting` marks this home as holding a call that may wait for a sitting, by
# touching state/.decision-sitting-waiting; bin/fm-captain-hold.sh runs it on
# every `reversible` hold. While the marker exists bin/fm-supervision-lib.sh
# counts the home as needing supervision, so the watcher that runs `due` keeps
# running after the last task is torn down. The marker holds a fresh token on
# every write, and a due sitting that finds nothing waiting removes it only
# when its token is unchanged since before the count was read, so a hold made
# during the read keeps it. It also stays while this home holds a reversible
# call that is blocked, or dated to open by the next sitting's day, because
# either may go live before a later sitting; an aged call, or one dated past
# the next sitting, does not keep the home supervised.
# It does nothing in a secondmate home: the parent records every secondmate
# under state/<mate-id>.meta, which already keeps the parent supervised.
#
# `queued` prints the waiting call ids, one per line (`<mate-id>/<task-id>` for
# a secondmate's), and is read-only apart from the snapshot's own cache refresh.
# `slots` prints the `last` and `next` sitting as `<label> <epoch> <local time>`.
#
# FM_DECISION_SITTING_TIMES (default "12:00 20:00", HH:MM in the zone; a time
# a daylight-saving jump skips holds no sitting that day, under GNU and BSD
# date alike) and
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
GRACE=${FM_DECISION_SITTING_GRACE:-3600}
case "$GRACE" in ''|*[!0-9]*) GRACE=3600 ;; esac
MARKER="$STATE/.last-decision-sitting"
WAITING="$STATE/.decision-sitting-waiting"
FAILED="$STATE/.last-decision-sitting-failed"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
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

# Epoch of <YYYY-MM-DD> <HH:MM> as wall-clock time in the sitting zone, or
# non-zero when that wall time does not exist there. BSD date normalises a time
# a daylight-saving jump skips instead of failing, so the result is read back.
zone_epoch() {  # <date> <HH:MM>
  local epoch
  epoch=$(TZ=$ZONE date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2:00" +%s 2>/dev/null) \
    || epoch=$(TZ=$ZONE date -d "$1 $2:00" +%s 2>/dev/null) \
    || return 1
  [ "$(zone_format "$epoch" '%Y-%m-%d %H:%M')" = "$1 $2" ] || return 1
  printf '%s\n' "$epoch"
}

# <epoch> rendered in the sitting zone with <format>.
zone_format() {  # <epoch> <format>
  TZ=$ZONE date -d "@$1" "+$2" 2>/dev/null && return 0
  TZ=$ZONE date -r "$1" "+$2" 2>/dev/null && return 0
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
      # A time a daylight-saving jump skips that day holds no sitting.
      t=$(zone_epoch "$day" "$t") || continue
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
  # Lift the snapshot's per-secondmate bounds so no waiting call falls past a cut.
  FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATES=100000 FM_SNAPSHOT_SECONDMATE_DECISIONS=100000 \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
}

# Every open reversible captain call that counts, one `<kind> <id>` line each:
# `live` waits for this sitting, and `pending` is this home's blocked call, or
# one dated to open on or before <next-day> (the next sitting's date in the
# zone), which may go live before a later sitting. Aged calls and calls dated
# further out print nothing.
reversible_calls() {  # <next-day>
  local json
  command -v jq >/dev/null 2>&1 || die "jq is required to count waiting calls"
  json=$(snapshot_json 2>/dev/null) || die "the fleet snapshot could not be read"
  printf '%s\n' "$json" | jq -r --arg next_day "$1" '
    def waits: (. // "") | tostring | startswith("[reversible");
    ([.backlog.records[]?
       | select(.structured and .hold_kind == "captain" and .state != "done"
                and (.hold_reason | waits))
       | if .hold_bucket == "live" then "live \(.id)"
         elif .hold_bucket == "blocked" then "pending \(.id)"
         elif .hold_bucket == "dated" and ((.hold_until // "") | tostring) <= $next_day then "pending \(.id)"
         else empty end]
     + [(.secondmate_current.records // [])[] as $m
        | $m.decisions_open[]?
        | select(.source == "backlog" and .verb == "captain-hold"
                 and .hold_bucket == "live" and (.reason | waits))
        | "live \($m.id)/\(.id)"])
    | unique | .[]' 2>/dev/null || die "the fleet snapshot could not be parsed"
}

next_day() {  # <epoch>
  local next
  next=$(next_sitting "$1") || exit 1
  zone_format "$next" %Y-%m-%d || die "cannot read the next sitting's date in $ZONE"
}

queued_ids() {
  local calls day
  day=$(next_day "$(now_epoch)") || exit 1
  calls=$(reversible_calls "$day") || exit 1
  printf '%s\n' "$calls" | sed -n 's/^live //p'
}

load_wake_lib() {
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"
}

record_sitting() {  # <epoch>
  printf '%s\n' "$1" > "$MARKER.tmp" && mv -f "$MARKER.tmp" "$MARKER"
}

# Queue one durable check wake keyed <key> unless it is still queued or the
# sitting <slot> was already recorded by a run that took the lock first.
# Prints `<key>\t<payload>` when it queued the row.
queue_once() {  # <slot> <key> <payload> <record-file>
  local slot=$1 key=$2 payload=$3 record=$4 queued recorded
  load_wake_lib || die "cannot load the wake library"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || die "cannot take the wake-queue lock"
  recorded=$(cat "$record" 2>/dev/null)
  case "$recorded" in ''|*[!0-9]*) recorded=0 ;; esac
  queued=$(fm_wake_queued_keys_locked check)
  if [ "$recorded" -ge "$slot" ]; then
    :
  elif printf '%s\n' "$queued" | grep -Fxq "$key"; then
    printf '%s\n' "$slot" > "$record" 2>/dev/null || true
  elif fm_wake_append_locked check "$key" "$payload"; then
    printf '%s\n' "$slot" > "$record" 2>/dev/null \
      || printf 'fm-decision-sitting: woke for %s but could not record it under %s\n' "$key" "$record" >&2
    printf '%s\t%s\n' "$key" "$payload"
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

# Remove the waiting marker only when its token is still <token>. The rename is
# atomic, so a `waiting` write after it creates a new marker that stays.
clear_waiting() {  # <token>
  local token=$1 claimed="$WAITING.clearing.$$"
  [ -n "$token" ] || return 0
  mv -f -- "$WAITING" "$claimed" 2>/dev/null || return 0
  if [ "present:$(cat "$claimed" 2>/dev/null)" = "$token" ]; then
    rm -f -- "$claimed"
  elif [ -e "$WAITING" ]; then
    rm -f -- "$claimed"
  else
    mv -f -- "$claimed" "$WAITING" 2>/dev/null || true
  fi
}

cmd_due() {
  local now slot recorded calls count stamp err label token day
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
  if [ $((now - slot)) -gt "$GRACE" ]; then
    record_sitting "$slot" || die "cannot record the sitting under $MARKER"
    return 0
  fi
  label=$(sitting_label "$slot")
  day=$(next_day "$now") || exit 1
  token=
  [ ! -e "$WAITING" ] || token="present:$(cat "$WAITING" 2>/dev/null || true)"
  stamp=$(mktemp "$STATE/.decision-sitting-read.XXXXXX") || die "cannot stage the sitting read under $STATE"
  if ! calls=$(reversible_calls "$day" 2>"$stamp"); then
    err=$(sed -n '1{s/^fm-decision-sitting: //;p;}' "$stamp")
    rm -f -- "$stamp"
    # Retried every tick; the captain-facing gap is reported once per sitting.
    queue_once "$slot" "decision-sitting-failed:$slot" \
      "check: decision sitting $label could not count the waiting calls (${err:-unknown error}); it retries every tick, so run bin/fm-decision-sitting.sh queued and hold this sitting by hand if it keeps failing" \
      "$FAILED"
    exit 1
  fi
  count=$(printf '%s\n' "$calls" | grep -c '^live ' || true)
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "$calls" | grep -q '^pending ' || clear_waiting "$token"
    rm -f -- "$stamp"
    record_sitting "$slot" || die "cannot record the sitting under $MARKER"
    return 0
  fi
  rm -f -- "$stamp"
  queue_once "$slot" "decision-sitting:$slot" \
    "check: decision sitting $label: $count call(s) waiting for the captain (bin/fm-decision-sitting.sh queued)" \
    "$MARKER"
}

cmd_waiting() {
  [ "$#" -eq 0 ] || die "usage: fm-decision-sitting.sh waiting"
  if fm_parent_channel_home_id "$FM_HOME" >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp=$(mktemp "$WAITING.XXXXXX") || die "cannot stage $WAITING"
  if ! { printf '%s.%s.%s\n' "$(date +%s)" "$$" "$RANDOM" > "$tmp" && mv -f -- "$tmp" "$WAITING"; }; then
    rm -f -- "$tmp"
    die "cannot mark $WAITING"
  fi
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
  waiting) shift; cmd_waiting "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
