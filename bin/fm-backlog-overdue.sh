#!/usr/bin/env bash
# fm-backlog-overdue.sh - wake firstmate once for dated backlog work its gate left stalled.
#
# Usage:
#   fm-backlog-overdue.sh scan
#
# A backlog item held with `tasks-axi hold --until <date>` (directly, through
# bin/fm-tasks-axi.sh, or as a captain deferral through bin/fm-captain-hold.sh)
# carries a date gate that tasks-axi lifts on that date. Nothing else notices
# when the gate opens, so an approved, dated item can sit queued for days.
# `scan` is the watcher's hourly backstop for that: a still-open queued row is
# overdue when tasks-axi reports its dated hold inactive, its gate opened at
# least the grace period ago, it has no unresolved blocker, and no task record
# (state/<id>.meta) shows it dispatched. The gate opens at 00:00 UTC of the
# hold-until date; the grace is 12 hours (FM_BACKLOG_OVERDUE_GRACE_SECS, in
# seconds), which leaves firstmate's own heartbeat re-evaluation of queued work
# most of the gate's first day before this fires.
#
# Each overdue row gets exactly one durable `check:` wake keyed
# `backlog-overdue:<id>`, whose payload names the task id, its gate date, and
# how many hours it is overdue. The marker state/backlog-overdue/<id> records
# the gate date it fired for, so the row stays quiet on every later scan.
# Dispatching the row, answering or lifting its hold, closing it, or giving it
# an unresolved blocker takes it off the overdue set, and the next scan removes
# its marker; a later gate that again lapses therefore wakes once more, as does
# a re-held row with a new date. The marker write and the append share the
# wake-queue lock, and a key still queued gets no second row.
#
# Prints one `overdue <id>` line per wake it queued, so bin/fm-watch.sh
# can wake once for the batch. A home with no readable tasks-axi backlog (a
# manual backend, a missing backlog, or tasks-axi absent) prints nothing and
# exits 0; a backlog read that fails or cannot be parsed exits 1 and leaves
# every marker in place, so a failed read never re-fires or clears anything.
# FM_BACKLOG_OVERDUE_NOW (epoch seconds) overrides the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

MARKERS="$STATE/backlog-overdue"
GRACE=${FM_BACKLOG_OVERDUE_GRACE_SECS:-43200}
case "$GRACE" in ''|*[!0-9]*) GRACE=43200 ;; esac

usage() {
  sed -n '2,34{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-backlog-overdue: %s\n' "$1" >&2
  exit 1
}

# Every queued row with an inactive dated hold, as `<id>\t<hold-until>\t<title>`.
# Only the trailing requested fields are split off the listing - hold_until,
# held, and blocked are slugs that follow the title - so a title holding commas
# or quotes cannot shift them.
gate_passed_rows() {  # <listing>
  printf '%s\n' "$1" | awk '
    /^  [A-Za-z0-9._-]+,/ {
      n = split($0, f, ",")
      if (n < 8) next
      id = f[1]; sub(/^ +/, "", id)
      if (f[2] != "queued" || f[n - 1] != "no" || f[n] != "no") next
      until = f[n - 2]
      if (until !~ /^[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]$/) next
      title = f[5]
      for (i = 6; i <= n - 3; i++) title = title "," f[i]
      if (title ~ /^".*"$/) { title = substr(title, 2, length(title) - 2); gsub(/\\"/, "\"", title) }
      printf "%s\t%s\t%s\n", id, until, title
    }
  '
}

load_wake_lib() {
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"
}

cmd_scan() {
  local now listing rows id until title opened age hours marker queued candidates='' payload
  [ "$#" -eq 0 ] || die "usage: fm-backlog-overdue.sh scan"
  now=${FM_BACKLOG_OVERDUE_NOW:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) die "FM_BACKLOG_OVERDUE_NOW must be epoch seconds" ;; esac
  command -v tasks-axi >/dev/null 2>&1 || return 0
  ! fm_backlog_backend_manual "$CONFIG" || return 0
  fm_backlog_tasks_axi_addressing "$DATA" || return 0
  [ -z "$FM_BACKLOG_AXI_FILE" ] || [ -f "$FM_BACKLOG_AXI_FILE" ] || return 0
  listing=$(FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-15} \
    fm_backlog_row_list "$DATA" --state queued --limit 1000000 --fields hold_until,held,blocked 2>&1) \
    || die "backlog read failed: $(printf '%s\n' "$listing" | sed -n '1p')"
  printf '%s\n' "$listing" | grep -q '^count: [0-9]' \
    || die "backlog listing could not be parsed: $(printf '%s\n' "$listing" | sed -n '1p')"
  rows=$(gate_passed_rows "$listing")

  while IFS=$'\t' read -r id until title; do
    [ -n "$id" ] || continue
    [ ! -e "$STATE/$id.meta" ] || continue
    candidates="$candidates$id"$'\n'
    opened=$(fm_utc_iso_to_epoch "${until}T00:00:00Z") || continue
    age=$((now - opened))
    [ "$age" -ge "$GRACE" ] || continue
    marker="$MARKERS/$id"
    [ "$(cat "$marker" 2>/dev/null)" != "$until" ] || continue
    hours=$((age / 3600))
    payload="check: backlog $id overdue: its date gate $until opened ${hours}h ago and it is still queued, not dispatched or answered - ${title:0:120}"
    command -v fm_wake_append_locked >/dev/null 2>&1 || load_wake_lib \
      || die "cannot load the wake library to report $id"
    (umask 077; mkdir -p "$MARKERS") || die "cannot create $MARKERS"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || die "cannot take the wake-queue lock"
    queued=$(fm_wake_queued_keys_locked check)
    if printf '%s\n' "$queued" | grep -Fxq "backlog-overdue:$id"; then
      printf '%s\n' "$until" > "$marker" 2>/dev/null || true
    elif fm_wake_append_locked check "backlog-overdue:$id" "$payload"; then
      printf '%s\n' "$until" > "$marker" 2>/dev/null \
        || printf 'fm-backlog-overdue: woke for %s but could not record it under %s\n' "$id" "$MARKERS" >&2
      printf 'overdue %s\n' "$id"
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  done <<EOF
$rows
EOF

  # A row that left the gate-passed set was dispatched, answered, re-dated,
  # blocked, or closed: clear its marker so a later lapse wakes again.
  [ -d "$MARKERS" ] || return 0
  for marker in "$MARKERS"/*; do
    [ -f "$marker" ] || continue
    id=${marker##*/}
    case $'\n'"$candidates" in
      *$'\n'"$id"$'\n'*) ;;
      *) rm -f -- "$marker" ;;
    esac
  done
}

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
