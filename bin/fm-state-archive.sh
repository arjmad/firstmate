#!/usr/bin/env bash
# fm-state-archive.sh - move old, settled state/ records into data/archive/state/
# so state/ stays small, without deleting anything.
#
# Usage: fm-state-archive.sh [--dry-run]
#          Prints one "BOOTSTRAP_INFO: state archive: ..." line when something
#          was moved (or, under --dry-run, would have been) and nothing
#          otherwise. Every problem is a "warning:" on stderr and the exit
#          status stays 0, so a session start continues.
#        --dry-run
#          Classify and report exactly as a real run would, move nothing, and
#          list each record that would move.
#
# bin/fm-bootstrap.sh runs it last in its deferred half, after the arming
# steps, under the fleet-lock holder check and a 30s bound, and never under
# FM_BOOTSTRAP_DETECT_ONLY=1.
#
# What moves. Two kinds of record, each older than
# FM_STATE_ARCHIVE_MAX_AGE_DAYS by its mtime:
#   - a captain note firstmate acknowledged, state/inbox/handled/<id>.note
#     (bin/fm-inbox.sh), to data/archive/state/<YYYY-MM>/inbox/, unless it
#     carries a request_id (a retry must replay it, not recreate it) or has a
#     reply under state/inbox/.replies/ (replies and receipts read the note);
#   - the captured results of a retired process-event source,
#     state/procevent-inbox/<source>.<seq>.* (bin/fm-procevent.sh), to
#     data/archive/state/<YYYY-MM>/procevent-inbox/, aged by each round's
#     .handled marker.
# <YYYY-MM> is the month of the record's mtime. A destination that already
# exists is never overwritten; the record stays and is named in a warning.
#
# What stays. A note an unhandled wake still names stays. A source's rounds
# move only together, and only when every one of its rounds is handled and
# old enough, the source has no `<source>.source` registration
# (state/procevent/), no queued wake names it, no watcher marker
# (.seen-procevent-*) carries its key, no unhandled task steer under
# state/*.inbox/ names one of its results, and its source lock is free.
# Under that lock it first raises the source's sequence floor,
# state/procevent-inbox/<source>.seq-floor (fm_procevent_sequence_floor), to
# its highest archived sequence; every capture allocator starts above the
# floor, so a source that registers again never reuses an archived sequence,
# its handled marker or a task pointer's text. The floor file itself stays.
# Within a round the .result moves first and the .handled marker last, so an
# interrupted move never leaves a result that reads as unhandled
# (fm_procevent_pending), and the next run finishes the round.
#
# Cost bound. A home that never archived holds thousands of old records, so
# one run moves at most FM_STATE_ARCHIVE_BUDGET notes and source rounds and
# stops scanning once it has, leaving the rest for the next session start;
# the summary says when more remain. Records it keeps are scanned every run,
# so the caller's time bound, not the budget, caps a run's time.
set -u

case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_STATE_ARCHIVE_MAX_AGE_DAYS=30
# Notes plus process-event rounds one run moves; see "Cost bound". Tests lower it.
FM_STATE_ARCHIVE_BUDGET=${FM_STATE_ARCHIVE_BUDGET:-1000}
case "$FM_STATE_ARCHIVE_BUDGET" in ''|*[!0-9]*) FM_STATE_ARCHIVE_BUDGET=1000 ;; esac

DRY_RUN=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo 'usage: fm-state-archive.sh [--dry-run]' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'usage: fm-state-archive.sh [--dry-run]' >&2; exit 2; }

warn() { printf 'warning: state archive: %s\n' "$*" >&2; }

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

MAX_AGE=$((FM_STATE_ARCHIVE_MAX_AGE_DAYS * 86400))
ARCHIVE_ROOT="$DATA/archive/state"
MOVED_NOTES=0 MOVED_ROUNDS=0 MOVED_SOURCES=0 MORE=0 SPENT=0

old_enough() { [ "$(fm_path_age "$1")" -gt "$MAX_AGE" ]; }

month_of() {  # <path>
  local m
  m=$(fm_path_mtime "$1") || return 1
  date -u -d "@$m" +%Y-%m 2>/dev/null || date -u -r "$m" +%Y-%m
}

# move_one <src> <dest-dir>: never overwrites; fails without moving.
move_one() {
  local dest="$2/${1##*/}"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    warn "kept ${1#"$STATE"/}: $dest already exists"
    return 1
  fi
  mkdir -p -- "$2" || { warn "could not create $2"; return 1; }
  mv -- "$1" "$dest" || { warn "could not move ${1#"$STATE"/}"; return 1; }
}

# --- what live records still name --------------------------------------------

QUEUE_KEYS=
read_queue_keys() {
  local status
  [ -e "$FM_WAKE_QUEUE" ] || [ -L "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 10 || return 1
  QUEUE_KEYS=$(awk -F '\t' 'NF >= 5 { print $4 }' "$FM_WAKE_QUEUE")
  status=$?
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
  return "$status"
}

queue_names() {  # <fixed text>
  [ -n "$QUEUE_KEYS" ] || return 1
  printf '%s\n' "$QUEUE_KEYS" | grep -F -q -- "$1"
}

# Unhandled task steers, read once: a result any of them names stays.
STEER_BODIES=
read_steers() {
  local msg body
  for msg in "$STATE"/*.inbox/*.msg; do
    [ -f "$msg" ] || continue
    body=$(fm_task_inbox_body "$msg" 2>/dev/null) || body=$(cat "$msg" 2>/dev/null) || return 1
    STEER_BODIES="$STEER_BODIES$body"$'\n'
  done
}

steer_names() {  # <fixed text>
  [ -n "$STEER_BODIES" ] || return 1
  case "$STEER_BODIES" in *"$1"*) return 0 ;; esac
  return 1
}

# --- captain notes -------------------------------------------------------------

archive_notes() {
  local note id dest
  for note in "$STATE/inbox/handled"/*.note; do
    # A spent budget stops the scan too: the rest costs forks the bound needs.
    if [ "$SPENT" -ge "$FM_STATE_ARCHIVE_BUDGET" ]; then
      MORE=1
      break
    fi
    [ -f "$note" ] && [ ! -L "$note" ] || continue
    old_enough "$note" || continue
    id=${note##*/}
    id=${id%.note}
    queue_names "$id" && continue
    [ ! -e "$STATE/inbox/.replies/$id" ] || continue
    [ -z "$(sed -n '/^--$/q;/^request_id=./p' "$note" 2>/dev/null)" ] || continue
    SPENT=$((SPENT + 1))
    dest="$ARCHIVE_ROOT/$(month_of "$note")/inbox"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would archive inbox/handled/%s\n' "${note##*/}"
      MOVED_NOTES=$((MOVED_NOTES + 1))
    elif move_one "$note" "$dest"; then
      MOVED_NOTES=$((MOVED_NOTES + 1))
    fi
  done
}

# --- process-event rounds --------------------------------------------------------

# round_files <inbox> <source> <seq>: every file of exactly this round, the
# .handled marker last; a longer source id that starts with `<source>.` never
# matches, because a round file's suffix holds no dot.
round_files() {
  local f rest
  for f in "$1/$2.$3".*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rest=${f#"$1/$2.$3."}
    # seq-floor here is source `<source>.<seq>`'s own floor, not a round file.
    case "$rest" in *.*|handled|seq-floor) continue ;; esac
    printf '%s\n' "$f"
  done
  [ -e "$1/$2.$3.handled" ] && printf '%s\n' "$1/$2.$3.handled"
}

# source_archivable <inbox> <source>: every round handled and old, and nothing
# live names the source. Prints the source's sequences.
source_archivable() {
  local inbox=$1 id=$2 reg f seq seqs='' marker
  reg=$(fm_procevent_registry_dir "$STATE")
  [ ! -e "$reg/$id.source" ] && [ ! -L "$reg/$id.source" ] || return 1
  queue_names "procevent:$id:" && return 1
  marker=$(fm_wake_procevent_marker_path "$STATE" "procevent:$id:") || return 1
  for f in "$marker"*; do
    [ -e "$f" ] && return 1
  done
  for f in "$inbox/$id".*.result "$inbox/$id".*.handled; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    seq=${f#"$inbox/$id."}
    seq=${seq%.*}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    case " $seqs " in *" $seq "*) continue ;; esac
    seqs="$seqs $seq"
  done
  [ -n "$seqs" ] || return 1
  for seq in $seqs; do
    f="$inbox/$id.$seq.handled"
    [ -f "$f" ] && [ ! -L "$f" ] && old_enough "$f" || return 1
    steer_names "$inbox/$id.$seq.result" && return 1
  done
  # shellcheck disable=SC2086 # one sequence per word
  printf '%s\n' $seqs
}

# write_floor <inbox> <source> <seqs>: atomically raise <source>.seq-floor
# (fm_procevent_sequence_floor) to the highest of <seqs>; never lowers it.
write_floor() {
  local floor seq tmp
  floor=$(fm_procevent_sequence_floor "$1" "$2")
  for seq in $3; do [ "$seq" -le "$floor" ] || floor=$seq; done
  tmp=$(umask 077; mktemp "$1/.$2.seq-floor.XXXXXX") || return 1
  if ! printf '%s\n' "$floor" > "$tmp" || ! mv -f -- "$tmp" "$1/$2.seq-floor"; then
    rm -f -- "$tmp"
    return 1
  fi
}

archive_source() {  # <inbox> <source> <seqs>
  local inbox=$1 id=$2 seqs=$3 seq f dest lock rc=0
  lock=$(fm_procevent_source_lock_path "$id")
  if [ "$DRY_RUN" -eq 0 ]; then
    (umask 077; mkdir -p "$(fm_procevent_claim_root)") || return 0
    fm_lock_try_acquire "$lock" || return 0
    # Re-check under the lock: a registration may have appeared meanwhile.
    if [ -e "$(fm_procevent_registry_dir "$STATE")/$id.source" ]; then
      fm_lock_release "$lock" || true
      return 0
    fi
    # Raise the sequence floor before anything moves, so neither a later
    # capture nor an interrupted move can ever reuse an archived sequence.
    if ! write_floor "$inbox" "$id" "$seqs"; then
      warn "could not record the sequence floor of $id; moved nothing of it"
      fm_lock_release "$lock" || true
      return 0
    fi
  fi
  for seq in $seqs; do
    dest="$ARCHIVE_ROOT/$(month_of "$inbox/$id.$seq.handled")/procevent-inbox"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would archive procevent-inbox/%s.%s.*\n' "$id" "$seq"
      MOVED_ROUNDS=$((MOVED_ROUNDS + 1))
      continue
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      move_one "$f" "$dest" || { rc=1; break; }
    done <<EOF
$(round_files "$inbox" "$id" "$seq")
EOF
    [ "$rc" -eq 0 ] || break
    MOVED_ROUNDS=$((MOVED_ROUNDS + 1))
  done
  [ "$DRY_RUN" -eq 1 ] || fm_lock_release "$lock" || true
  [ "$rc" -eq 0 ] && MOVED_SOURCES=$((MOVED_SOURCES + 1))
  return 0
}

archive_procevent() {
  local inbox f id seen='' seqs count
  inbox=$(fm_procevent_inbox_dir "$STATE")
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || return 0
  for f in "$inbox"/*.handled; do
    if [ "$SPENT" -ge "$FM_STATE_ARCHIVE_BUDGET" ]; then
      MORE=1
      break
    fi
    [ -f "$f" ] || continue
    id=$(fm_procevent_result_source_id "${f%.handled}.result")
    fm_procevent_source_id_valid "$id" || continue
    case "$seen" in *"|$id|"*) continue ;; esac
    seen="$seen|$id|"
    seqs=$(source_archivable "$inbox" "$id") || continue
    count=$(printf '%s\n' "$seqs" | wc -l | tr -d ' ')
    if [ $((SPENT + count)) -gt "$FM_STATE_ARCHIVE_BUDGET" ] && [ "$SPENT" -gt 0 ]; then
      MORE=1
      continue
    fi
    SPENT=$((SPENT + count))
    archive_source "$inbox" "$id" "$(printf '%s ' "$seqs" | tr '\n' ' ')"
  done
}

# --- main ----------------------------------------------------------------------------

if ! read_queue_keys; then
  warn "could not read the wake queue; moved nothing"
  exit 0
fi
if ! read_steers; then
  warn "could not read every task steer; moved nothing"
  exit 0
fi
archive_notes
archive_procevent

if [ "$MOVED_NOTES" -gt 0 ] || [ "$MOVED_ROUNDS" -gt 0 ]; then
  verb=moved
  [ "$DRY_RUN" -eq 0 ] || verb='would move'
  printf 'BOOTSTRAP_INFO: state archive: %s %s handled note(s) and %s process-event round(s) of %s retired source(s) older than %s days to data/archive/state/' \
    "$verb" "$MOVED_NOTES" "$MOVED_ROUNDS" "$MOVED_SOURCES" "$FM_STATE_ARCHIVE_MAX_AGE_DAYS"
  [ "$MORE" -eq 0 ] || printf '; more remain for the next session start'
  printf '\n'
fi
exit 0
