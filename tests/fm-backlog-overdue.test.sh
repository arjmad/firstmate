#!/usr/bin/env bash
# Behavior tests for bin/fm-backlog-overdue.sh: a queued backlog item whose date
# gate opened more than the grace period ago without a dispatch or answer wakes
# firstmate exactly once, with a reason naming it and how long it is overdue,
# and a later dispatch or answer clears it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-backlog-overdue.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-overdue)
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# 2026-10-24T00:00:00Z, the gate of the dated rows below.
GATE_EPOCH=1792800000
HOUR=3600

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null 2>&1 \
    || fail "tasks-axi $* failed in $home"
}

add_dated() {  # <home> <id> <title> <until>
  axi "$1" add "$2" --title "$3"
  axi "$1" hold "$2" --reason "run on the day" --kind future --until "$4"
}

scan_at() {  # <home> <epoch>
  FM_HOME="$1" FM_BACKLOG_OVERDUE_NOW="$2" "$SCAN" scan
}

queued_rows() {  # <home> <id>
  grep -c "$(printf '\tcheck\tbacklog-overdue:%s\t' "$2")" "$1/state/.wake-queue" 2>/dev/null || true
}

# Drop every queued row, as firstmate's post-handling acknowledgement does.
ack_all() {  # <home>
  : > "$1/state/.wake-queue"
}

test_overdue_item_wakes_once_with_its_reason() {
  local home out row
  home=$(new_home once)
  add_dated "$home" price-ladder 'Run the price ladder, "Friday"' 2026-10-24
  out=$(scan_at "$home" $((GATE_EPOCH + 14 * HOUR))) || fail "scan failed: $out"
  assert_equals "$out" "overdue price-ladder" "scan did not report the overdue item"
  row=$(grep "$(printf '\tbacklog-overdue:price-ladder\t')" "$home/state/.wake-queue")
  assert_contains "$row" 'check: backlog price-ladder overdue: its date gate 2026-10-24 opened 14h ago' \
    "the wake reason did not name the item, its gate, and how long it is overdue"
  assert_contains "$row" 'Run the price ladder, "Friday"' "the wake reason lost the item title"

  ack_all "$home"
  out=$(scan_at "$home" $((GATE_EPOCH + 40 * HOUR))) || fail "second scan failed: $out"
  assert_equals "$out" "" "a second scan re-reported an item already woken for"
  assert_equals "$(queued_rows "$home" price-ladder)" 0 "a second scan queued another wake for the same gate"
  pass "an overdue item wakes firstmate once, naming it and how long it is overdue"
}

test_grace_period_bounds_the_wake() {
  local home out
  home=$(new_home grace)
  add_dated "$home" dated-job 'Dated job' 2026-10-24
  out=$(scan_at "$home" $((GATE_EPOCH + 11 * HOUR))) || fail "scan failed: $out"
  assert_equals "$out" "" "an item inside its 12-hour grace was reported"
  out=$(scan_at "$home" $((GATE_EPOCH + 12 * HOUR))) || fail "scan failed: $out"
  assert_equals "$out" "overdue dated-job" "an item at the end of its grace was not reported"
  pass "the wake fires once the 12-hour grace after the gate has passed, not before"
}

test_waiting_or_dispatched_items_stay_quiet() {
  local home out
  home=$(new_home quiet)
  add_dated "$home" not-yet 'Still gated' 2099-01-01
  add_dated "$home" blocker 'Blocker' 2099-01-01
  add_dated "$home" blocked 'Blocked behind the blocker' 2026-10-24
  axi "$home" block blocked --by blocker
  add_dated "$home" dispatched 'Has a task record' 2026-10-24
  : > "$home/state/dispatched.meta"
  add_dated "$home" flying 'Already in flight' 2026-10-24
  axi "$home" start flying
  axi "$home" add undated --title 'No date gate'
  out=$(scan_at "$home" $((GATE_EPOCH + 100 * HOUR))) || fail "scan failed: $out"
  assert_equals "$out" "" "a gated, blocked, dispatched, in-flight, or undated item was reported"
  [ ! -s "$home/state/.wake-queue" ] || fail "quiet items queued a wake: $(cat "$home/state/.wake-queue")"
  pass "items still gated, blocked, dispatched, in flight, or undated never wake"
}

test_dispatch_or_answer_clears_and_a_new_lapse_wakes_again() {
  local home out
  home=$(new_home clear)
  add_dated "$home" answered 'Captain answered' 2026-10-24
  add_dated "$home" dispatched 'Later dispatched' 2026-10-24
  out=$(scan_at "$home" $((GATE_EPOCH + 13 * HOUR))) || fail "scan failed: $out"
  assert_equals "$(printf '%s\n' "$out" | LC_ALL=C sort | paste -sd ' ' -)" "overdue answered overdue dispatched" \
    "both items were not reported"
  ack_all "$home"

  axi "$home" unhold answered
  : > "$home/state/dispatched.meta"
  out=$(scan_at "$home" $((GATE_EPOCH + 14 * HOUR))) || fail "scan failed: $out"
  assert_equals "$out" "" "an answered or dispatched item was reported"
  assert_absent "$home/state/backlog-overdue/answered" "the answered item's overdue marker was not cleared"
  assert_absent "$home/state/backlog-overdue/dispatched" "the dispatched item's overdue marker was not cleared"

  axi "$home" hold answered --reason "run again" --kind future --until 2026-10-25
  rm -f "$home/state/dispatched.meta"
  out=$(scan_at "$home" $((GATE_EPOCH + 37 * HOUR))) || fail "scan failed: $out"
  assert_equals "$(printf '%s\n' "$out" | LC_ALL=C sort | paste -sd ' ' -)" "overdue answered overdue dispatched" \
    "a cleared item whose gate lapsed again did not wake again"
  assert_contains "$(cat "$home/state/.wake-queue")" "its date gate 2026-10-25 opened 13h ago" \
    "the re-held item's wake did not name its new gate"
  pass "a dispatch or answer clears the overdue mark, and a later lapse wakes once more"
}

test_still_queued_key_is_not_duplicated() {
  local home out
  home=$(new_home dedup)
  add_dated "$home" dated-job 'Dated job' 2026-10-24
  out=$(scan_at "$home" $((GATE_EPOCH + 13 * HOUR))) || fail "scan failed: $out"
  rm -rf "$home/state/backlog-overdue"
  out=$(scan_at "$home" $((GATE_EPOCH + 14 * HOUR))) || fail "scan failed: $out"
  assert_equals "$out" "" "a scan re-reported an item whose wake is still queued"
  assert_equals "$(queued_rows "$home" dated-job)" 1 "a still-queued wake was duplicated"
  assert_present "$home/state/backlog-overdue/dated-job" "the marker was not restored for the queued wake"
  pass "an item whose wake is still queued never gets a second row"
}

test_failed_backlog_read_changes_nothing() {
  local home fakebin out rc
  home=$(new_home failed-read)
  add_dated "$home" dated-job 'Dated job' 2026-10-24
  scan_at "$home" $((GATE_EPOCH + 13 * HOUR)) >/dev/null || fail "first scan failed"
  ack_all "$home"
  fakebin=$(fm_fakebin "$TMP_ROOT/failed-read-bin")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
echo "backend unavailable" >&2
exit 1
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" scan_at "$home" $((GATE_EPOCH + 14 * HOUR)) 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a failed backlog read exited $rc, want 1: $out"
  assert_contains "$out" "backlog read failed" "the failed read was not reported"
  assert_present "$home/state/backlog-overdue/dated-job" "a failed read cleared an overdue marker"
  [ ! -s "$home/state/.wake-queue" ] || fail "a failed read queued a wake"
  pass "a failed backlog read neither wakes nor clears anything"
}

test_home_without_backlog_is_silent() {
  local home out
  home="$TMP_ROOT/no-backlog"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$SCAN" scan 2>&1) || fail "a home without a backlog failed: $out"
  assert_equals "$out" "" "a home without a backlog printed output"
  pass "a home without a tasks-axi backlog scans silently"
}

test_overdue_item_wakes_once_with_its_reason
test_grace_period_bounds_the_wake
test_waiting_or_dispatched_items_stay_quiet
test_dispatch_or_answer_clears_and_a_new_lapse_wakes_again
test_still_queued_key_is_not_duplicated
test_failed_backlog_read_changes_nothing
test_home_without_backlog_is_silent
