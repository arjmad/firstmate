#!/usr/bin/env bash
# Behavior tests for bin/fm-backlog-prune.sh: the weekly Monday slot and its
# snooze, the recorded offer a board card names, and the drops an answer
# orders - each a reopenable tasks-axi close with a dated note, re-checked
# against the backlog as it is when the answer arrives.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRUNE="$ROOT/bin/fm-backlog-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-prune)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
# The slot is local time; a zone with daylight saving keeps that honest.
export TZ=America/New_York

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# Local wall-clock time to epoch seconds, in this suite's zone.
at() {  # <YYYY-MM-DD> <HH:MM>
  perl -MPOSIX=mktime -e 'my ($y,$m,$d) = split /-/, $ARGV[0]; my ($H,$M) = split /:/, $ARGV[1];
    print mktime(0, $M, $H, $d, $m - 1, $y - 1900, 0, 0, -1), "\n"' "$1" "$2"
}

# 2026-10-26 is a Monday. Rows are stale against it unless their dates say not.
make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] stale-one - Old fleet errand one (repo: business) (kind: ship) (since 2026-09-01)
  Owner: fleet
- [ ] stale-two - Old fleet errand two (repo: fleet) (kind: task) (since 2026-09-02)
  Owner: fleet
- [ ] stale-three - Old fleet errand three (repo: business) (kind: ship) (since 2026-09-03)
  Owner: fleet
- [ ] his-own - His own old to-do (repo: sites) (kind: captain) (since 2026-09-01)
  Owner: arjun
- [ ] waits-on-four - Fresh work waiting on four blocked-by: stale-four (repo: business) (kind: ship) (since 2026-10-20)
  Owner: fleet
- [ ] stale-four - Old errand other work waits on (repo: business) (kind: ship) (since 2026-09-04)
  Owner: fleet
## Done
EOF
  printf '%s\n' "$home"
}

prune() {  # <home> <epoch> <args...>
  local home=$1 now=$2
  shift 2
  FM_HOME="$home" FM_PRUNE_NOW="$now" "$PRUNE" "$@"
}

MONDAY=$(at 2026-10-26 09:00)

test_the_slot_opens_monday_morning_local_time() {
  local home
  home=$(make_home slot)
  [ "$(prune "$home" "$(at 2026-10-26 05:59)" schedule | jq -r .slot)" = 2026-10-19 ] \
    || fail "before 06:00 on Monday the slot had already moved to the new week"
  prune "$home" "$(at 2026-10-26 06:00)" schedule \
    | jq -e '.slot == "2026-10-26" and .open == true and .slot_opens == "2026-10-26T10:00:00Z" and .answered_at == null' >/dev/null \
    || fail "the slot did not open at 06:00 local on Monday"
  [ "$(prune "$home" "$(at 2026-11-01 23:00)" schedule | jq -r .slot)" = 2026-10-26 ] \
    || fail "Sunday night did not still belong to the Monday slot"
  [ "$(prune "$home" "$(at 2026-11-02 07:00)" schedule | jq -r .slot_opens)" = 2026-11-02T11:00:00Z ] \
    || fail "the slot did not follow the local clock across the daylight-saving change"
  pass "the weekly slot opens every Monday at 06:00 local time"
}

test_status_proposes_only_stale_fleet_rows() {
  local home
  home=$(make_home status)
  prune "$home" "$MONDAY" status | jq -e '
    .due == true and .age_days == 14
      and ([.candidates[].id] == ["stale-one", "stale-two", "stale-three"])
      and (.candidates[0] | .title == "Old fleet errand one" and .repo == "business" and .touched == "2026-09-01")
  ' >/dev/null || fail "status did not propose exactly the stale fleet rows, oldest first"
  pass "status lists the stale fleet rows oldest first and says the card is due"
}

test_an_offer_records_exactly_the_shown_list() {
  local home key again other rc i case
  home=$(make_home offer)
  key=$(prune "$home" "$MONDAY" offer 2026-10-26 stale-one stale-two) || fail "a current-slot offer was refused"
  printf '%s' "$key" | grep -Eq '^prune\.2026-10-26\.[0-9a-f]{8}$' || fail "the offer key is not prune.<slot>.<digest>: $key"
  jq -e '.ids == ["stale-one", "stale-two"] and .slot == "2026-10-26"' "$home/state/backlog-prune/offers/$key.json" >/dev/null \
    || fail "the offer did not record the list in order"
  again=$(prune "$home" "$MONDAY" offer 2026-10-26 stale-one stale-two)
  [ "$again" = "$key" ] || fail "the same list did not give the same key"
  other=$(prune "$home" "$MONDAY" offer 2026-10-26 stale-two stale-one)
  [ "$other" != "$key" ] || fail "a different order gave the same key, so positions could name the wrong rows"
  for case in "2026-10-19 stale-one" "2026-10-26 bad/id" "2026-10-26 stale-one stale-one" "2026-10-26"; do
    rc=0
    # shellcheck disable=SC2086 # each case is a word list
    prune "$home" "$MONDAY" offer $case >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "offer accepted '$case' (exit $rc)"
  done
  for i in 1 2 3 4 5 6 7 8 9; do
    prune "$home" "$MONDAY" offer 2026-10-26 "row-$i" >/dev/null || fail "offer $i failed"
  done
  [ "$(find "$home/state/backlog-prune/offers" -name 'prune.*.json' | wc -l | tr -d ' ')" -le 8 ] \
    || fail "offers beyond the newest 8 were kept"
  pass "an offer records the card's exact list under a key that changes with the list, for the current slot only"
}

test_drop_all_closes_each_row_with_a_reopenable_dated_note() {
  local home key out
  home=$(make_home drop-all)
  printf 'Arjun\n' > "$home/config/captain-name"
  key=$(prune "$home" "$MONDAY" offer 2026-10-26 stale-one stale-two stale-three ghost stale-four)
  # Touched after the card was built: the dated note makes it fresh again.
  perl -0pi -e 's/(stale-two .*\n)/$1  2026-10-25: keep this one, the vendor replied\n/' "$home/data/backlog.md"
  out=$(prune "$home" "$MONDAY" apply "$key" drop-all) || fail "drop-all failed: $out"
  assert_contains "$out" "dropped: stale-one" "drop-all did not drop a stale row: $out"
  assert_contains "$out" "skipped: stale-two (touched 2026-10-25)" "drop-all dropped a row touched since the card: $out"
  assert_contains "$out" "dropped: stale-three" "drop-all did not drop every offered row: $out"
  assert_contains "$out" "skipped: ghost (not in the backlog)" "drop-all did not name an absent row: $out"
  assert_contains "$out" "skipped: stale-four (open work waits on it)" "drop-all dropped a row other work waits on: $out"
  assert_contains "$out" "answered: 2026-10-26 drop-all" "drop-all did not record the answer: $out"
  awk '/^## Done/{d=1} d' "$home/data/backlog.md" | grep -q "^  dropped by Arjun's prune, 2026-10-26$" \
    || fail "a dropped row does not carry the dated prune note"
  prune "$home" "$MONDAY" schedule | jq -e '.open == false and .answer == "drop-all"' >/dev/null \
    || fail "the card stayed due after its answer"
  prune "$home" "$((MONDAY + 7 * 86400))" schedule | jq -e '.open == true and .slot == "2026-11-02"' >/dev/null \
    || fail "the card did not come back next Monday"
  out=$(prune "$home" "$MONDAY" apply "$key" drop-all) || fail "re-running drop-all failed: $out"
  assert_contains "$out" "skipped: stale-one (no longer queued)" "a re-run did not see the drop already done: $out"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" reopen stale-one >/dev/null || fail "a dropped row could not be reopened"
  prune "$home" "$MONDAY" status | jq -e '[.candidates[].id] | index("stale-one") == null' >/dev/null \
    || fail "a reopened row was proposed again before two weeks passed"
  pass "drop-all closes each still-stale row with a dated note, skips the rest by name, and any drop reopens"
}

test_drop_picked_drops_only_those_positions() {
  local home key out rc
  home=$(make_home drop-picked)
  key=$(prune "$home" "$MONDAY" offer 2026-10-26 stale-one stale-two stale-three)
  rc=0; prune "$home" "$MONDAY" apply "$key" drop-picked 1,4 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a position past the end of the offer was accepted (exit $rc)"
  out=$(prune "$home" "$MONDAY" apply "$key" drop-picked 3,1,3) || fail "drop-picked failed: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^dropped: ')" = 2 ] || fail "drop-picked dropped other than the picked rows: $out"
  assert_contains "$out" "dropped: stale-one" "drop-picked missed position 1: $out"
  assert_contains "$out" "dropped: stale-three" "drop-picked missed position 3: $out"
  grep -q '^- \[ \] stale-two ' "$home/data/backlog.md" || fail "an unpicked row was dropped"
  grep -q "^  dropped by the captain's prune, 2026-10-26$" "$home/data/backlog.md" \
    || fail "with no captain name configured the note did not say the captain"
  pass "drop-picked drops only the rows at the picked positions"
}

test_keep_snoozes_the_card_for_a_week() {
  local home key wednesday out rc
  home=$(make_home keep)
  wednesday=$(at 2026-10-28 15:00)
  key=$(prune "$home" "$wednesday" offer 2026-10-26 stale-one)
  out=$(prune "$home" "$wednesday" apply "$key" keep) || fail "keep failed: $out"
  assert_contains "$out" "snoozed-until: 2026-11-04" "keep did not snooze a week: $out"
  grep -q '^- \[ \] stale-one ' "$home/data/backlog.md" || fail "keep dropped a row"
  prune "$home" "$(at 2026-11-02 09:00)" schedule | jq -e '.open == false' >/dev/null \
    || fail "a keep on Wednesday came back before its week was up"
  prune "$home" "$(at 2026-11-04 08:00)" schedule | jq -e '.open == true' >/dev/null \
    || fail "the card did not come back when its snooze ran out"
  rc=0; prune "$home" "$wednesday" apply prune.2026-10-26.00000000 keep >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an answer naming no recorded offer was accepted (exit $rc)"
  pass "keep drops nothing and brings the card back a week later"
}

test_an_earlier_weeks_answer_leaves_this_weeks_card() {
  local home key out next
  home=$(make_home earlier-week)
  key=$(prune "$home" "$MONDAY" offer 2026-10-26 stale-one)
  next=$((MONDAY + 7 * 86400))
  out=$(prune "$home" "$next" apply "$key" drop-all) || fail "a late drop-all failed: $out"
  assert_contains "$out" "dropped: stale-one" "a late answer did not drop what its card named: $out"
  assert_contains "$out" "an earlier week's card; this week's card is unchanged" "a late answer did not say it left this week alone: $out"
  prune "$home" "$next" schedule | jq -e '.open == true and .answered_at == null' >/dev/null \
    || fail "a late answer to last week's card closed this week's"
  pass "an answer to an earlier week's card drops its rows but leaves this week's card due"
}

test_the_age_threshold_is_parsed_once_and_refused_when_bad() {
  local home rc v
  home=$(make_home age)
  FM_BACKLOG_PRUNE_AGE_DAYS=030 prune "$home" "$MONDAY" status | jq -e '.age_days == 30 and ([.candidates[].id] == ["stale-one", "stale-two", "stale-three"])' >/dev/null \
    || fail "a zero-padded threshold was not read as decimal days"
  for v in 0 -3 two 1e2; do
    rc=0
    FM_BACKLOG_PRUNE_AGE_DAYS=$v prune "$home" "$MONDAY" status >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "the threshold '$v' was not refused (exit $rc)"
  done
  pass "the age threshold is one decimal parse, and anything but a positive whole number is refused"
}

test_the_slot_opens_monday_morning_local_time
test_status_proposes_only_stale_fleet_rows
test_an_offer_records_exactly_the_shown_list
test_drop_all_closes_each_row_with_a_reopenable_dated_note
test_drop_picked_drops_only_those_positions
test_keep_snoozes_the_card_for_a_week
test_an_earlier_weeks_answer_leaves_this_weeks_card
test_the_age_threshold_is_parsed_once_and_refused_when_bad
