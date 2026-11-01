#!/usr/bin/env bash
# Decision sittings: bin/fm-decision-sitting.sh finds the 12:00 and 20:00
# sittings in the named zone across a daylight-saving change, counts only live
# reversible captain calls as waiting, queues one durable check wake per due
# sitting that has calls waiting, stays silent for a sitting with none, and
# does nothing in a secondmate home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-sitting)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
[ -f "${TZDIR:-/usr/share/zoneinfo}/America/New_York" ] || [ -f /var/db/timezone/zoneinfo/America/New_York ] \
  || { echo "skip: America/New_York zoneinfo not installed"; exit 0; }

SITTING="$ROOT/bin/fm-decision-sitting.sh"

# 2026-10-31 is still daylight time in New York (UTC-4); 2026-11-01 is the
# first day of standard time (UTC-5), so its 12:00 is an hour later in UTC.
OCT31_NOON=1793462400   # 2026-10-31T16:00:00Z
OCT31_EVENING=1793491200 # 2026-11-01T00:00:00Z
NOV01_NOON=1793552400   # 2026-11-01T17:00:00Z
NOV01_EVENING=1793581200 # 2026-11-02T01:00:00Z

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_sitting() {  # <home> <now> <command args...>
  local home=$1 now=$2
  shift 2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DECISION_SITTING_NOW="$now" "$SITTING" "$@"
}

hold_call() {  # <home> <id> <hold args...>
  local home=$1 id=$2
  shift 2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" --title "Call $id" --reason "Decide $id" "$@" >/dev/null \
    || fail "could not hold $id"
}

sitting_rows() {  # <home>
  awk -F '\t' '$3 == "check" && $4 ~ /^decision-sitting:/ { n++ } END { print n + 0 }' \
    "$1/state/.wake-queue" 2>/dev/null || echo 0
}

test_sittings_follow_the_named_zone_across_daylight_saving() {
  local home out
  home=$(make_home slots)
  out=$(run_sitting "$home" $((OCT31_NOON + 1800)) slots) || fail "slots failed: $out"
  assert_contains "$out" "last $OCT31_NOON 2026-10-31 12:00 America/New_York" "the daylight-time noon sitting was wrong: $out"
  assert_contains "$out" "next $OCT31_EVENING 2026-10-31 20:00 America/New_York" "the daylight-time evening sitting was wrong: $out"
  out=$(run_sitting "$home" $((OCT31_EVENING + 3600)) slots) || fail "slots failed: $out"
  assert_contains "$out" "last $OCT31_EVENING " "the evening sitting before the change was not the last one: $out"
  assert_contains "$out" "next $NOV01_NOON 2026-11-01 12:00 America/New_York" \
    "the first standard-time noon sitting was not at 17:00 UTC: $out"
  out=$(run_sitting "$home" "$NOV01_NOON" slots) || fail "slots failed: $out"
  assert_contains "$out" "last $NOV01_NOON " "a sitting at exactly its time was not due: $out"
  assert_contains "$out" "next $NOV01_EVENING 2026-11-01 20:00 America/New_York" "the standard-time evening sitting was wrong: $out"
  if out=$(FM_DECISION_SITTING_ZONE=Not/AZone run_sitting "$home" "$NOV01_NOON" slots 2>&1); then
    fail "an unknown zone was accepted and would have read as UTC: $out"
  fi
  if out=$(FM_DECISION_SITTING_TIMES="12:00 25:00" run_sitting "$home" "$NOV01_NOON" slots 2>&1); then
    fail "a sitting time that is not HH:MM was accepted: $out"
  fi
  pass "sittings land at 12:00 and 20:00 New York time on both sides of the daylight-saving change"
}

test_only_live_reversible_calls_wait() {
  local home out
  home=$(make_home queued)
  hold_call "$home" waits-default --kind reversible --default "ship it" --options "ship it|drop" --recommend "ship it"
  hold_call "$home" waits-open --kind reversible --no-default
  hold_call "$home" at-once --kind arjun-only --options "Spend|Skip" --recommend Skip
  hold_call "$home" no-kind
  hold_call "$home" deferred --kind reversible --until 2099-01-01
  out=$(run_sitting "$home" "$NOV01_NOON" queued) || fail "queued failed: $out"
  assert_equals "$(printf 'waits-default\nwaits-open')" "$out" \
    "only the live reversible calls should wait for a sitting"
  pass "a sitting counts only live reversible calls, never arjun-only, unkinded, or dated ones"
}

test_due_sitting_wakes_once_and_an_empty_one_stays_silent() {
  local home out
  home=$(make_home due)
  out=$(run_sitting "$home" $((OCT31_NOON + 60)) due) || fail "first due failed: $out"
  assert_equals "" "$out" "a home's first tick should only start the cadence"
  assert_equals "$OCT31_NOON" "$(cat "$home/state/.last-decision-sitting")" "the first tick did not record the sitting"

  out=$(run_sitting "$home" $((OCT31_EVENING + 60)) due) || fail "empty due failed: $out"
  assert_equals "" "$out" "a sitting with nothing waiting printed output"
  assert_equals "0" "$(sitting_rows "$home")" "a sitting with nothing waiting queued a wake"
  assert_equals "$OCT31_EVENING" "$(cat "$home/state/.last-decision-sitting")" "the empty sitting was not recorded"

  hold_call "$home" waits --kind reversible --no-default
  hold_call "$home" urgent --kind arjun-only
  out=$(run_sitting "$home" $((NOV01_NOON + 120)) due) || fail "due failed: $out"
  assert_equals "check: decision sitting 2026-11-01 12:00 America/New_York: 1 call(s) waiting for the captain (bin/fm-decision-sitting.sh queued)" \
    "$out" "the due sitting did not name its time and count"
  assert_equals "1" "$(sitting_rows "$home")" "the due sitting was not queued durably"
  grep -F "$(printf '\tcheck\tdecision-sitting:%s\t' "$NOV01_NOON")" "$home/state/.wake-queue" >/dev/null \
    || fail "the wake was not keyed by its sitting: $(cat "$home/state/.wake-queue")"

  out=$(run_sitting "$home" $((NOV01_NOON + 600)) due) || fail "repeat due failed: $out"
  assert_equals "" "$out" "the same sitting woke twice"
  rm -f "$home/state/.last-decision-sitting"
  printf '%s\n' "$OCT31_EVENING" > "$home/state/.last-decision-sitting"
  out=$(run_sitting "$home" $((NOV01_NOON + 900)) due) || fail "replayed due failed: $out"
  assert_equals "1" "$(sitting_rows "$home")" "a sitting still queued got a second row"
  pass "a due sitting with calls waiting queues one durable wake and an empty sitting says nothing"
}

test_secondmate_home_runs_no_sittings() {
  local home out
  home=$(make_home mate)
  printf 'mate-one\n' > "$home/.fm-secondmate-home"
  printf '%s\n' "$OCT31_NOON" > "$home/state/.last-decision-sitting"
  # The fixture home has no parent binding, so hold reports the channel it could not reach.
  hold_call "$home" waits --kind reversible --no-default 2>/dev/null
  out=$(run_sitting "$home" $((NOV01_NOON + 60)) due) || fail "due failed in a secondmate home: $out"
  assert_equals "" "$out" "a secondmate home ran its own sitting"
  assert_equals "$OCT31_NOON" "$(cat "$home/state/.last-decision-sitting")" "a secondmate home recorded a sitting"
  pass "a secondmate home runs no sittings of its own"
}

test_secondmate_calls_count_in_the_parent_sitting() {
  local home snap out
  home=$(make_home parent)
  snap="$home/snapshot.json"
  jq -n '{backlog:{records:[]},
          secondmate_current:{records:[{id:"mate-one",decisions_open:[
            {id:"pick-plan",verb:"captain-hold",source:"backlog",hold_bucket:"live",reason:"[reversible; default: A; releases 2026-11-04T00:00:00Z] pick"},
            {id:"pay-vendor",verb:"captain-hold",source:"backlog",hold_bucket:"live",reason:"[arjun-only] pay"},
            {id:"status-ask",verb:"needs-decision",source:"status",reason:"[reversible] stray"}]}]}}' > "$snap"
  out=$(FM_DECISION_SITTING_SNAPSHOT="$snap" run_sitting "$home" "$NOV01_NOON" queued) || fail "queued failed: $out"
  assert_equals "mate-one/pick-plan" "$out" "a secondmate's reversible call did not wait in the parent's sitting"
  printf '{"backlog":' > "$snap"
  if out=$(FM_DECISION_SITTING_SNAPSHOT="$snap" run_sitting "$home" "$NOV01_NOON" queued 2>&1); then
    fail "an unreadable snapshot was counted as nothing waiting: $out"
  fi
  printf '%s\n' "$OCT31_EVENING" > "$home/state/.last-decision-sitting"
  if FM_DECISION_SITTING_SNAPSHOT="$snap" run_sitting "$home" "$NOV01_NOON" due >/dev/null 2>&1; then
    fail "a due sitting whose snapshot failed reported success"
  fi
  assert_equals "$OCT31_EVENING" "$(cat "$home/state/.last-decision-sitting")" \
    "a failed snapshot read advanced the sitting, so the next tick would not retry it"
  pass "a secondmate's waiting calls count in its parent's sitting, and a failed read retries"
}

test_sittings_follow_the_named_zone_across_daylight_saving
test_only_live_reversible_calls_wait
test_due_sitting_wakes_once_and_an_empty_one_stays_silent
test_secondmate_home_runs_no_sittings
test_secondmate_calls_count_in_the_parent_sitting
