#!/usr/bin/env bash
# Hold kinds for captain-held tasks: `hold --kind`, the reason prefix every
# hold surface shows, and the retired default release (`--default` and
# `--no-default` are refused, and a row that still carries a default waits
# like any other); the row owner each hold and release records; and the
# choices a hold records (`--options`, `--recommend`, `--ask`, `choices`) and
# the keyed pick by label.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-kind)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

show_task() {  # <home> <id>
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" show "$2" --full
}

task_owner() {  # <home> <id>
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" owner "$2"
}

test_kind_arguments_are_validated() {
  local home id args
  home=$(make_home validation)
  for args in \
    "--kind maybe" \
    "--kind reversible --default ship-it" \
    "--kind reversible --no-default"; do
    id=sample-$RANDOM
    # shellcheck disable=SC2086 # Word splitting builds each refused argument set.
    if run_captain "$home" hold "$id" --title "Refused call" --reason "decide" $args \
      > "$home/out" 2> "$home/err"; then
      fail "hold accepted the invalid kind arguments: $args"
    fi
  done
  if run_captain "$home" hold sample-prefixed --title "Prefixed call" \
    --reason "[arjun-only] spoofed" > "$home/out" 2> "$home/err"; then
    fail "hold accepted a reason that already carries a kind prefix"
  fi
  assert_grep "kind prefix" "$home/err" "the spoofed prefix refusal did not say why"
  if grep -q 'sample-' "$home/data/backlog.md"; then
    fail "a refused hold still wrote a backlog row: $(cat "$home/data/backlog.md")"
  fi
  pass "invalid kinds, the retired default flags, and spoofed prefixes are refused before any write"
}

# Every hold waits for the captain's answer. The flags that configured the
# retired 72-hour default release are refused and say what to use instead, and
# a reversible hold needs nothing beyond its kind.
test_holds_wait_for_the_captains_answer() {
  local home flag show
  home=$(make_home waits)
  for flag in --default --no-default; do
    if run_captain "$home" hold sample-retired --title "Retired flag" --reason "keep or drop" \
      --kind reversible "$flag" x > "$home/out" 2> "$home/err"; then
      fail "hold accepted the retired $flag flag"
    fi
    assert_grep "$flag was removed" "$home/err" "the $flag refusal did not say it was removed"
    assert_grep "--options and --recommend" "$home/err" "the $flag refusal did not say what to use instead"
  done
  run_captain "$home" hold sample-call --title "Pick the font" --reason "serif or sans" \
    --kind reversible >/dev/null || fail "a reversible hold with no other flag was refused"
  show=$(show_task "$home" sample-call)
  assert_contains "$show" '[reversible] serif or sans' "the reversible hold did not store its plain prefix"
  assert_contains "$show" 'held: yes' "the reversible hold was not held"
  pass "holds wait for the answer: the default flags are refused and a reversible hold needs only its kind"
}

# A row held before the default release was removed can still carry its
# `default: ...; releases ...` segment. That default was the call's
# recommendation, so each re-hold drops the segment and keeps the option.
give_retired_default() {  # <home> <id> <decoded-prefix-and-reason>
  (cd "$1" && tasks-axi hold "$2" --kind captain --file "$1/data/backlog.md" --reason "$3") >/dev/null \
    || fail "could not give $2 the retired default prefix"
}

# It stays held past its old release time, and `choices` with no --recommend
# takes the default as the recommendation.
test_choices_keeps_a_retired_default_as_the_recommendation() {
  local home show
  home=$(make_home retired-default)
  run_captain "$home" hold sample-docs --title "Docs layout" --reason "Split the guide" \
    --kind reversible >/dev/null || fail "could not hold the call"
  give_retired_default "$home" sample-docs "[reversible; default: split; releases 2026-10-17T10:00:00Z] Split the guide"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" 'default: split; releases 2026-10-17T10:00:00Z' "the fixture did not record the retired default"
  assert_contains "$show" 'held: yes' "a row whose old release time passed was released"
  FM_CAPTAIN_HOLD_NOW=2026-10-20T10:00:00Z run_captain "$home" choices sample-docs \
    --options "split|keep" >/dev/null || fail "choices on a row with a retired default failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" '[reversible; options: split|keep; recommended: split] Split the guide' \
    "choices did not take the retired default as the recommendation"
  assert_not_contains "$show" 'default: split' "choices kept the retired default"
  pass "choices drops a retired default and keeps it as the recommendation"
}

# `defer` on a call with no options keeps the default in the reason.
test_defer_keeps_a_retired_default_as_the_recommendation() {
  local home show reason
  home=$(make_home retired-default-defer)
  run_captain "$home" hold sample-docs --title "Docs layout" --reason "Split the guide" \
    --kind reversible >/dev/null || fail "could not hold the call"
  give_retired_default "$home" sample-docs "[reversible; default: split; releases 2026-10-17T10:00:00Z] Split the guide"
  printf 'Arjun: ask me next week\n' > "$home/defer.txt"
  FM_CAPTAIN_HOLD_NOW=2026-10-20T10:00:00Z run_captain "$home" defer sample-docs --until 2026-10-27 \
    --decision-file "$home/defer.txt" >/dev/null || fail "the deferral of a row with a retired default failed"
  show=$(show_task "$home" sample-docs)
  reason=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: "\(.*\)"$/\1/p')
  reason=$(bash -c '. "$1/bin/fm-hold-reason-lib.sh"; fm_hold_reason_decode "$2"' _ "$ROOT" "$reason")
  assert_equals '[reversible] Split the guide (recommended: split)' "$reason" \
    "defer did not keep the retired default as the recommendation"
  assert_contains "$show" 'hold_until: 2026-10-27' "defer did not record its date"
  pass "defer drops a retired default and keeps it as the recommendation"
}

# `retire-defaults` re-holds every row that still carries a default, keeping it
# as the recommendation, and leaves every other hold alone.
test_retire_defaults_rewrites_every_retired_default() {
  local home out show
  home=$(make_home retire-defaults)
  run_captain "$home" hold sample-plain --title "Plain call" --reason "Keep or drop" \
    --kind reversible >/dev/null || fail "could not hold the plain call"
  run_captain "$home" hold sample-choice --title "Choice call" --reason "Pick the font" \
    --kind reversible >/dev/null || fail "could not hold the choice call"
  give_retired_default "$home" sample-choice \
    "[reversible; default: sans; releases 2026-10-17T10:00:00Z; options: serif|sans; recommended: sans; ask: Which font?] Pick the font"
  run_captain "$home" hold sample-bare --title "Bare call" --reason "Keep the banner" \
    --kind reversible >/dev/null || fail "could not hold the bare call"
  give_retired_default "$home" sample-bare "[reversible; default: drop it; releases 2026-10-17T10:00:00Z] Keep the banner"
  out=$(run_captain "$home" retire-defaults) || fail "retire-defaults failed: $out"
  assert_contains "$out" 'retired default: sample-choice sans' "the choice call was not retired"
  assert_contains "$out" 'retired default: sample-bare drop it' "the bare call was not retired"
  assert_not_contains "$out" 'sample-plain' "a call with no default was retired"
  show=$(show_task "$home" sample-choice)
  assert_contains "$show" '[reversible; options: serif|sans; recommended: sans; ask: Which font?] Pick the font' \
    "the choice call lost its choices or kept its default"
  show=$(show_task "$home" sample-bare)
  assert_contains "$show" '[reversible] Keep the banner (recommended: drop it)' "the bare call did not keep its default as the recommendation"
  assert_contains "$show" 'held: yes' "retire-defaults lifted a hold"
  out=$(run_captain "$home" retire-defaults) || fail "a second retire-defaults failed: $out"
  assert_equals "" "$out" "a second retire-defaults found a default again"
  pass "retire-defaults turns every retired default into the recommendation, once"
}

test_kind_prefix_shows_on_every_hold_reason() {
  local home show
  home=$(make_home prefix)
  run_captain "$home" hold sample-money --title "Spend on a tool" \
    --reason "Buy the plan (about 4 USD a month)?" --kind arjun-only >/dev/null \
    || fail "an arjun-only hold failed"
  show=$(show_task "$home" sample-money)
  assert_contains "$show" '[arjun-only] Buy the plan (about 4 USD a month)?' \
    "the arjun-only kind did not show on the decoded reason"
  run_captain "$home" hold sample-docs \
    --title "Docs layout" --reason "Split the guide or keep one page" --kind reversible >/dev/null \
    || fail "a reversible hold failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" '[reversible] Split the guide or keep one page' \
    "the reversible kind did not show on the reason"
  run_captain "$home" hold sample-plain --title "Plain call" --reason "no kind given" >/dev/null \
    || fail "a hold without a kind failed"
  show=$(show_task "$home" sample-plain)
  assert_not_contains "$show" '[reversible' "a hold without a kind gained a kind"
  pass "the kind rides on the stored reason that every hold surface decodes"
}

# A call held for the captain is his next move, so hold records him as the
# owner, from the first write of a row it creates; releasing the hold hands
# the work back to the fleet, while a closing answer leaves the owner alone.
test_hold_records_the_captain_as_owner_and_release_hands_back() {
  local home body
  home=$(make_home owner)
  run_captain "$home" hold sample-new --title "Pick the box" --reason "small or large" --origin origin-x >/dev/null \
    || fail "could not create and hold a call"
  assert_equals arjun "$(task_owner "$home" sample-new)" "a created call did not name the captain as its owner"
  body=$(show_task "$home" sample-new)
  assert_contains "$body" 'Captain hold set: ' "the created call lost its hold-set stamp"
  assert_contains "$body" 'Captain hold origin: origin-x' "the created call lost its origin line"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add sample-ship "Ship the box change" --kind ship --repo sample >/dev/null \
    || fail "could not add the work row"
  assert_equals fleet "$(task_owner "$home" sample-ship)" "the work row did not start as the fleet's"
  run_captain "$home" hold sample-ship --reason "ship now or after the audit" >/dev/null \
    || fail "could not hold the work row"
  assert_equals arjun "$(task_owner "$home" sample-ship)" "holding work for the captain did not make it his"
  [ "$(grep -c '^  Owner: ' "$home/data/backlog.md")" = 2 ] \
    || fail "a held row carries more than one owner line: $(cat "$home/data/backlog.md")"
  printf 'Ship it now.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-ship --decision-file "$home/answer.txt" --release >/dev/null \
    || fail "the released answer was refused"
  assert_equals fleet "$(task_owner "$home" sample-ship)" "a released hold did not hand the work back to the fleet"
  # A replay finishes a release whose owner write never landed.
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" owner sample-ship arjun >/dev/null || fail "could not reset the owner"
  run_captain "$home" answer sample-ship --decision-file "$home/answer.txt" --release >/dev/null \
    || fail "the replayed release was refused"
  assert_equals fleet "$(task_owner "$home" sample-ship)" "a replayed release did not hand the work back to the fleet"
  run_captain "$home" answer sample-new --decision-file "$home/answer.txt" >/dev/null \
    || fail "the closing answer was refused"
  assert_equals arjun "$(task_owner "$home" sample-new)" "a closing answer changed the owner"
  pass "hold makes the captain the owner and a released hold hands the work back to the fleet"
}

test_choice_arguments_are_validated() {
  local home id args
  home=$(make_home choice-validation)
  for args in \
    "--options A|B --recommend A" \
    "--kind arjun-only --options A|B" \
    "--kind arjun-only --recommend A" \
    "--kind arjun-only --options A --recommend A" \
    "--kind arjun-only --options A|B|C|D --recommend A" \
    "--kind arjun-only --options A|a --recommend A" \
    "--kind arjun-only --options A||B --recommend A" \
    "--kind arjun-only --options A|later --recommend A" \
    "--kind arjun-only --options A|Reconcile --recommend A" \
    "--kind arjun-only --options A;x|B --recommend B" \
    "--kind arjun-only --options A|B --recommend C" \
    "--kind reversible --options A|B" \
    "--kind arjun-only --ask has]bracket" \
    "--kind arjun-only --ask has;semicolon"; do
    id=choice-$RANDOM
    # shellcheck disable=SC2086 # Word splitting builds each refused argument set.
    if run_captain "$home" hold "$id" --title "Refused call" --reason "decide" $args \
      > "$home/out" 2> "$home/err"; then
      fail "hold accepted the invalid choice arguments: $args"
    fi
  done
  if run_captain "$home" hold choice-spoof --title "Spoofed choices" \
    --reason "[arjun-only; options: Pay|Skip; recommended: Pay] x" > "$home/out" 2> "$home/err"; then
    fail "hold accepted a reason that already carries a choices prefix"
  fi
  if run_captain "$home" hold choice-long --title "Long choice" --reason "decide" --kind arjun-only \
    --options "$(printf 'x%.0s' $(seq 1 61))|B" --recommend B > "$home/out" 2> "$home/err"; then
    fail "hold accepted a choice over 60 bytes"
  fi
  if grep -q 'choice-' "$home/data/backlog.md"; then
    fail "a refused hold still wrote a backlog row: $(cat "$home/data/backlog.md")"
  fi
  pass "hold refuses choices that are unkinded, unrecommended, too many, repeated, reserved or malformed"
}

test_choices_ride_on_the_reason_prefix() {
  local home show
  home=$(make_home choice-prefix)
  run_captain "$home" hold sample-fba --title "Deduct the FBA shipment" \
    --reason "Deducting all leaves 401 below the floor" --kind arjun-only \
    --options " Deduct all | Not yet " --recommend "Deduct all" \
    --ask "Deduct the whole FBA shipment from the warehouse now?" >/dev/null \
    || fail "an arjun-only hold with choices failed"
  show=$(show_task "$home" sample-fba)
  assert_contains "$show" \
    '[arjun-only; options: Deduct all|Not yet; recommended: Deduct all; ask: Deduct the whole FBA shipment from the warehouse now?] Deducting all leaves 401 below the floor' \
    "the arjun-only choices did not ride on the reason"
  run_captain "$home" hold sample-docs \
    --title "Docs layout" --reason "Split the guide or keep one page" --kind reversible \
    --options "split the guide|keep one page" --recommend "split the guide" >/dev/null \
    || fail "a reversible hold with choices failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" \
    '[reversible; options: split the guide|keep one page; recommended: split the guide] Split the guide' \
    "the reversible choices did not ride on the reason"
  run_captain "$home" hold sample-idea --title "An idea" --reason "Try it?" \
    --kind reversible --ask "Should we try it?" >/dev/null \
    || fail "a hold with only a question failed"
  show=$(show_task "$home" sample-idea)
  assert_contains "$show" '[reversible; ask: Should we try it?] Try it?' "an ask without choices did not ride on the reason"
  # A re-hold that passes no choices drops them with the old reason.
  run_captain "$home" hold sample-fba --reason "Count first" --kind arjun-only >/dev/null \
    || fail "the plain re-hold failed"
  show=$(show_task "$home" sample-fba)
  assert_contains "$show" '[arjun-only] Count first' "a re-hold without choices kept the old ones"
  pass "choices ride on the stored reason prefix and die with it"
}

test_choices_set_choices_on_an_active_hold() {
  local home show
  home=$(make_home choice-set)
  run_captain "$home" hold sample-docs \
    --title "Docs layout" --reason "Split the guide (or not)" --kind reversible >/dev/null \
    || fail "the reversible hold failed"
  run_captain "$home" choices sample-docs \
    --options "build|skip" --recommend build --ask "Build it?" >/dev/null || fail "choices on a reversible hold failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" \
    '[reversible; options: build|skip; recommended: build; ask: Build it?] Split the guide (or not)' \
    "choices did not keep the reason and kind"
  run_captain "$home" choices sample-docs --options "build|wait" --recommend build >/dev/null \
    || fail "replacing choices failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" 'options: build|wait; recommended: build; ask: Build it?]' \
    "replacing the choices did not keep the recorded question"
  run_captain "$home" hold sample-dated --title "Dated call" --reason "Later call" \
    --kind arjun-only --until 2026-12-01 >/dev/null || fail "the dated hold failed"
  run_captain "$home" choices sample-dated --options "Go|Stop" --recommend Go >/dev/null \
    || fail "choices on a dated hold failed"
  show=$(show_task "$home" sample-dated)
  assert_contains "$show" '[arjun-only; options: Go|Stop; recommended: Go] Later call' "choices on a dated hold were not recorded"
  assert_contains "$show" 'hold_until: 2026-12-01' "choices dropped the hold date"
  printf 'Arjun: later\n' > "$home/defer.txt"
  run_captain "$home" defer sample-dated --until 2026-12-09 --decision-file "$home/defer.txt" >/dev/null \
    || fail "the deferral failed"
  show=$(show_task "$home" sample-dated)
  assert_contains "$show" '[arjun-only; options: Go|Stop; recommended: Go] Later call' "a deferral dropped the choices"
  # A re-hold between choices' read and its write is never overwritten.
  if FM_CAPTAIN_HOLD_EXPECT_REASON="[arjun-only] an older reason" run_captain "$home" hold sample-dated \
    --reason "Later call" --kind arjun-only --until 2026-12-09 --options "Go|Stop" --recommend Stop \
    > "$home/out" 2> "$home/err"; then
    fail "a re-hold whose reason changed since it was read was not refused"
  fi
  assert_grep "re-held since it was read" "$home/err" "the changed-reason refusal did not say why"
  run_captain "$home" hold sample-bare --title "Bare call" --reason "no kind" >/dev/null || fail "the bare hold failed"
  if run_captain "$home" choices sample-bare --options "A|B" --recommend A > "$home/out" 2> "$home/err"; then
    fail "choices accepted a hold with no kind"
  fi
  printf 'Arjun: build\n' > "$home/answer.txt"
  run_captain "$home" answer sample-docs --decision-file "$home/answer.txt" --release >/dev/null \
    || fail "the release failed"
  if run_captain "$home" choices sample-docs --options "A|B" --recommend A > "$home/out" 2> "$home/err"; then
    fail "choices re-held a released call"
  fi
  assert_contains "$(show_task "$home" sample-docs)" 'held: no' "a refused choices call left the row held"
  if run_captain "$home" choices sample-missing --options "A|B" --recommend A > "$home/out" 2> "$home/err"; then
    fail "choices created a missing row"
  fi
  pass "choices sets the choices on an active hold and keeps its reason, kind, date and question"
}

test_keyed_answer_records_a_pick_by_label() {
  local home show out
  home=$(make_home choice-pick)
  run_captain "$home" hold sample-fba --title "Deduct the FBA shipment" --reason "Decide" \
    --kind arjun-only --options "Deduct all|Not yet" --recommend "Deduct all" >/dev/null || fail "hold failed"
  out=$(printf 'sample-fba\tdeduct ALL \tDeduct all\n' | run_captain "$home" answers --source "test board") \
    || fail "the keyed pick was refused: $out"
  show=$(show_task "$home" sample-fba)
  assert_contains "$show" 'Answer: deduct ALL' "the pick did not keep the captain's own words"
  assert_contains "$show" 'Choice picked: Deduct all' "the pick was not recorded as the recorded choice"
  out=$(printf 'sample-fba\tdeduct ALL \tDeduct all\n' | run_captain "$home" answers --source "test board") \
    || fail "the replayed pick was not a no-op: $out"
  assert_contains "$out" 'closed: sample-fba' "the replayed pick did not report closed"
  run_captain "$home" hold sample-go --title "Go call" --reason "Decide" \
    --kind arjun-only --options "Go|Stop" --recommend Go >/dev/null || fail "hold failed"
  out=$(printf 'sample-go\tStop\tStop\trelease\n' | run_captain "$home" answers --source "test board") \
    || fail "the released pick was refused: $out"
  out=$(printf 'sample-go\tStop\tStop\trelease\n' | run_captain "$home" answers --source "test board") \
    || fail "the replayed released pick was not a no-op: $out"
  run_captain "$home" hold sample-lower --title "Lower call" --reason "Decide" \
    --kind arjun-only --options "Go|Stop" --recommend Go >/dev/null || fail "hold failed"
  out=$(printf 'sample-lower\tstop\t\trelease\n' | run_captain "$home" answers --source "test chat") \
    || fail "the lowercase released pick was refused: $out"
  out=$(printf 'sample-lower\tstop\t\trelease\n' | run_captain "$home" answers --source "test chat") \
    || fail "the replayed lowercase released pick was not a no-op: $out"
  run_captain "$home" hold sample-board --title "Board call" --reason "Decide" \
    --kind arjun-only --options "Deduct all|Not yet" --recommend "Deduct all" >/dev/null || fail "hold failed"
  printf 'sample-board\tdeduct-all\tDeduct all\n' | run_captain "$home" answers --source "bearings board" >/dev/null \
    || fail "a board pick by option value was refused"
  assert_contains "$(show_task "$home" sample-board)" 'Choice picked: Deduct all' \
    "a board pick whose shown label names the choice was not recorded as that pick"
  run_captain "$home" hold sample-free --title "Free call" --reason "Decide" \
    --kind arjun-only --options "Go|Stop" --recommend Go >/dev/null || fail "hold failed"
  printf 'sample-free\tGo, but only on Monday\t\n' | run_captain "$home" answers --source "test chat" >/dev/null \
    || fail "a free-text answer to a call with choices was refused"
  assert_not_contains "$(show_task "$home" sample-free)" 'Choice picked' "a free-text answer was recorded as a pick"
  pass "a keyed answer that names a recorded choice is recorded as that pick, replays idempotently, and free text still works"
}

test_kind_arguments_are_validated
test_choice_arguments_are_validated
test_choices_ride_on_the_reason_prefix
test_choices_set_choices_on_an_active_hold
test_keyed_answer_records_a_pick_by_label
test_holds_wait_for_the_captains_answer
test_choices_keeps_a_retired_default_as_the_recommendation
test_defer_keeps_a_retired_default_as_the_recommendation
test_retire_defaults_rewrites_every_retired_default
test_hold_records_the_captain_as_owner_and_release_hands_back
test_kind_prefix_shows_on_every_hold_reason
