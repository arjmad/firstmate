#!/usr/bin/env bash
# tests/fm-state-archive.test.sh - bin/fm-state-archive.sh, the locked
# session-start move of old handled captain notes and retired process-event
# rounds from state/ into data/archive/state/<YYYY-MM>/.
#
# The guarantees under test:
#   - A handled note older than 30 days moves to the month of its mtime; a
#     fresh one, and one a queued wake names, stay.
#   - A retired source whose every round is handled and old moves whole, each
#     round's .handled marker last; nothing of it is deleted.
#   - A registered source, a source with a fresh or unhandled round, one a
#     queued wake or watcher marker names, and one an unhandled task steer
#     points at all stay.
#   - A longer source id that starts with another's id is never swept with it.
#   - An existing destination is never overwritten.
#   - --dry-run reports and moves nothing; silence when nothing moves.
#   - The per-run budget defers the remainder to the next run.
# The locked-bootstrap seat is covered in tests/fm-data-media-prune.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-state-archive)
ARCHIVE="$ROOT/bin/fm-state-archive.sh"
OLD=$(( $(date +%s) - 40 * 86400 ))
OLD_MONTH=$(date -u -d "@$OLD" +%Y-%m 2>/dev/null || date -u -r "$OLD" +%Y-%m)

new_home() {
  local h="$TMP_ROOT/$1/home"
  mkdir -p "$h/state/inbox/handled" "$h/state/procevent" "$h/state/procevent-inbox" "$h/data" "$h/config"
  printf '%s\n' "$h"
}

run_archive() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$ARCHIVE" "$@" 2>&1
}

old_note() {  # <home> <id>
  printf 'schema=x\n--\nnote\n' > "$1/state/inbox/handled/$2.note"
  fm_touch_epoch "$OLD" "$1/state/inbox/handled/$2.note"
}

# round <home> <source> <seq> <old|fresh> [unhandled]
round() {
  local pin="$1/state/procevent-inbox" f
  printf 'result\n' > "$pin/$2.$3.result"
  printf 'lavish\n' > "$pin/$2.$3.adapter"
  printf 'task\n' > "$pin/$2.$3.owner-task"
  [ "${5:-}" = unhandled ] || : > "$pin/$2.$3.handled"
  if [ "$4" = old ]; then
    for f in "$pin/$2.$3".*; do fm_touch_epoch "$OLD" "$f"; done
  fi
}

arch() { printf '%s\n' "$1/data/archive/state/$OLD_MONTH/$2"; }

test_old_notes_move_and_live_ones_stay() {
  local home out
  home=$(new_home notes)
  old_note "$home" 1790000000-old
  old_note "$home" 1790000001-woken
  printf 'fresh\n' > "$home/state/inbox/handled/1795000000-new.note"
  printf '1\t0\tcheck\tinbox:1790000001-woken\tx\n' > "$home/state/.wake-queue"

  out=$(run_archive "$home" --dry-run)
  assert_contains "$out" "would archive inbox/handled/1790000000-old.note" "--dry-run should list the note: $out"
  [ -e "$home/state/inbox/handled/1790000000-old.note" ] || fail "--dry-run moved a note"

  out=$(run_archive "$home")
  [ -f "$(arch "$home" inbox)/1790000000-old.note" ] || fail "an old handled note should move to its month: $out"
  [ ! -e "$home/state/inbox/handled/1790000000-old.note" ] || fail "the moved note is still in state/"
  [ -e "$home/state/inbox/handled/1795000000-new.note" ] || fail "a fresh note must stay"
  [ -e "$home/state/inbox/handled/1790000001-woken.note" ] || fail "a note a queued wake names must stay"
  assert_contains "$out" "BOOTSTRAP_INFO: state archive: moved 1 handled note(s)" "summary line: $out"
  out=$(run_archive "$home")
  [ -z "$out" ] || fail "a converged home should be silent: $out"
  pass "archive: old handled notes move by month; fresh and woken ones stay"
}

test_retired_sources_move_whole_and_live_ones_stay() {
  local home out pin f marker
  home=$(new_home rounds)
  pin="$home/state/procevent-inbox"
  round "$home" gone 1 old; round "$home" gone 2 old
  round "$home" gone.x 1 fresh
  round "$home" reg 1 old; : > "$home/state/procevent/reg.source"
  round "$home" mixed 1 old; round "$home" mixed 2 fresh
  round "$home" unread 1 old; round "$home" unread 2 old unhandled
  round "$home" queued 1 old
  printf '1\t0\tprocevent\tprocevent:queued:1\tx\n' > "$home/state/.wake-queue"
  round "$home" marked 1 old
  marker=$(STATE="$home/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_procevent_marker_path "$2" "procevent:marked:1"' _ "$ROOT" "$home/state")
  : > "$marker"
  round "$home" pointed 1 old
  mkdir -p "$home/state/t.inbox"
  printf 'schema=fm-task-inbox.v1\n--\nread %s now\n' "$pin/pointed.1.result" > "$home/state/t.inbox/001.msg"

  out=$(run_archive "$home")
  for f in gone.1.result gone.1.adapter gone.1.owner-task gone.1.handled gone.2.result gone.2.handled; do
    [ -f "$(arch "$home" procevent-inbox)/$f" ] || fail "retired round file $f should move: $out"
    [ ! -e "$pin/$f" ] || fail "moved round file $f is still in state/"
  done
  [ -e "$pin/gone.x.1.result" ] || fail "a longer source id must not move with gone"
  for f in reg.1 mixed.1 unread.1 queued.1 marked.1 pointed.1; do
    [ -e "$pin/$f.result" ] && [ -e "$pin/$f.handled" ] || fail "round $f must stay: $out"
  done
  assert_contains "$out" "2 process-event round(s) of 1 retired source(s)" "summary line: $out"
  [ "$(cat "$pin/gone.seq-floor")" = 2 ] || fail "the archive should raise gone's sequence floor to 2"
  [ "$(bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"; fm_procevent_next_sequence "$2" gone' _ "$ROOT" "$pin")" = 3 ] \
    || fail "a later capture of gone must not reuse an archived sequence"
  pass "archive: a retired source's settled rounds move whole above a sequence floor; live ones stay"
}

test_linked_notes_stay() {
  local home
  home=$(new_home linked)
  printf 'request_id=handoff:x\n--\nnote\n' > "$home/state/inbox/handled/1790000000-req.note"
  fm_touch_epoch "$OLD" "$home/state/inbox/handled/1790000000-req.note"
  old_note "$home" 1790000001-replied
  mkdir -p "$home/state/inbox/.replies"
  printf 'reply\n' > "$home/state/inbox/.replies/1790000001-replied"
  run_archive "$home" >/dev/null
  [ -e "$home/state/inbox/handled/1790000000-req.note" ] || fail "a note with a request id must stay for its replay"
  [ -e "$home/state/inbox/handled/1790000001-replied.note" ] || fail "a note with a reply must stay for its receipts"
  pass "archive: notes a request id or a reply still reads stay"
}

test_existing_destination_is_never_overwritten() {
  local home out dest
  home=$(new_home clash)
  old_note "$home" 1790000000-clash
  dest=$(arch "$home" inbox)
  mkdir -p "$dest"
  printf 'earlier\n' > "$dest/1790000000-clash.note"
  out=$(run_archive "$home")
  [ "$(cat "$dest/1790000000-clash.note")" = earlier ] || fail "an existing archive file was overwritten"
  [ -e "$home/state/inbox/handled/1790000000-clash.note" ] || fail "the note should stay when its destination exists"
  assert_contains "$out" "already exists" "the kept note should be named: $out"
  pass "archive: an existing destination is never overwritten"
}

test_budget_defers_the_remainder() {
  local home out n
  home=$(new_home budget)
  for n in 1 2 3; do old_note "$home" "179000000$n-b"; done
  out=$(FM_STATE_ARCHIVE_BUDGET=2 run_archive "$home")
  assert_contains "$out" "moved 2 handled note(s)" "the budget should cap one run: $out"
  assert_contains "$out" "1 deferred to the next session start" "the rest should be reported deferred: $out"
  out=$(FM_STATE_ARCHIVE_BUDGET=2 run_archive "$home")
  assert_contains "$out" "moved 1 handled note(s)" "the next run should finish: $out"
  pass "archive: the per-run budget defers the remainder"
}

test_old_notes_move_and_live_ones_stay
test_retired_sources_move_whole_and_live_ones_stay
test_existing_destination_is_never_overwritten
test_budget_defers_the_remainder
test_linked_notes_stay
