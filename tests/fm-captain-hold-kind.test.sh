#!/usr/bin/env bash
# Hold kinds and default release for captain-held tasks: `hold --kind` and
# `--default`, the reason prefix every hold surface shows, and `release-due`,
# which records a due reversible default as the decision of record; the
# row owner each hold and release records; and the choices a hold records
# (`--options`, `--recommend`, `--ask`, `choices`) and the keyed pick by label.
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
    "--default ship-it" \
    "--kind arjun-only --default ship-it" \
    "--kind reversible --default bad]option" \
    "--kind reversible" \
    "--kind reversible --default ship-it --no-default" \
    "--kind reversible --default ship-it --until 2026-11-30" \
    "--kind arjun-only --no-default" \
    "--no-default"; do
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
  if run_captain "$home" hold sample-long --title "Long default" --reason "decide" \
    --kind reversible --default "$(printf 'x%.0s' $(seq 1 201))" > "$home/out" 2> "$home/err"; then
    fail "hold accepted a default over 200 bytes"
  fi
  if grep -q 'sample-' "$home/data/backlog.md"; then
    fail "a refused hold still wrote a backlog row: $(cat "$home/data/backlog.md")"
  fi
  pass "invalid kinds, defaults, and spoofed prefixes are refused before any write"
}

# A reversible call must say what happens if the captain never answers: a
# default that releases it, his own --until deferral, or an explicit
# --no-default. Omitting all three is refused and says how to fix it.
test_reversible_hold_names_its_default() {
  local home out show
  home=$(make_home names-default)
  if run_captain "$home" hold sample-bare --title "Bare reversible call" \
    --reason "keep or drop" --kind reversible > "$home/out" 2> "$home/err"; then
    fail "a reversible hold with no default, deferral, or --no-default was accepted"
  fi
  assert_grep "--default <option>" "$home/err" "the refusal did not name --default"
  assert_grep "--no-default" "$home/err" "the refusal did not name --no-default"
  if grep -q 'sample-bare' "$home/data/backlog.md"; then
    fail "the refused reversible hold still wrote a backlog row: $(cat "$home/data/backlog.md")"
  fi

  if run_captain "$home" hold sample-both --title "Deferred with a default" --reason "keep or drop" \
    --kind reversible --default keep --until 2026-11-30 > "$home/out" 2> "$home/err"; then
    fail "a reversible hold accepted a default beside the captain's deferral"
  fi
  assert_grep "deferred with --until takes no --default" "$home/err" \
    "the default-beside-deferral refusal did not say why"
  if run_captain "$home" hold sample-both --title "Deferred with a default" --reason "keep or drop" \
    --kind arjun-only --no-default > "$home/out" 2> "$home/err"; then
    fail "--no-default was accepted on an arjun-only hold"
  fi
  assert_grep "--no-default requires --kind reversible" "$home/err" \
    "the arjun-only --no-default refusal did not say why"

  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-idea \
    --title "An idea" --reason "build the widget or not" --kind reversible --no-default >/dev/null \
    || fail "a reversible hold with --no-default was refused"
  show=$(show_task "$home" sample-idea)
  assert_contains "$show" '[reversible] build the widget or not' \
    "--no-default did not store the plain reversible prefix"
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-later \
    --title "A deferred call" --reason "revisit the banner" --kind reversible --until 2026-11-30 >/dev/null \
    || fail "a reversible hold the captain deferred with --until was refused"
  show=$(show_task "$home" sample-later)
  assert_contains "$show" '[reversible] revisit the banner' \
    "the deferred reversible hold did not store the plain reversible prefix"

  # A re-hold must restate the choice, so it cannot silently drop a default.
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-call \
    --title "Pick the font" --reason "serif or sans" --kind reversible --default sans >/dev/null \
    || fail "a reversible hold with a default was refused"
  if FM_CAPTAIN_HOLD_NOW=2026-10-15T10:00:00Z run_captain "$home" hold sample-call \
    --reason "serif or sans, asked again" --kind reversible > "$home/out" 2> "$home/err"; then
    fail "a reversible re-hold dropped its default without saying so"
  fi
  show=$(show_task "$home" sample-call)
  assert_contains "$show" '[reversible; default: sans; releases 2026-10-17T10:00:00Z] serif or sans' \
    "the refused re-hold changed the stored default"

  out=$(FM_CAPTAIN_HOLD_NOW=2026-12-01T00:00:00Z run_captain "$home" release-due) \
    || fail "release-due failed"
  assert_contains "$out" "released by default: sample-call sans" "the defaulted call did not release"
  assert_not_contains "$out" "sample-idea" "a --no-default hold released itself"
  assert_not_contains "$out" "sample-later" "a deferred reversible hold released itself"
  pass "a reversible hold names a default, a deferral, or --no-default, and only a default releases"
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
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-docs \
    --title "Docs layout" --reason "Split the guide or keep one page" \
    --kind reversible --default "split the guide" >/dev/null \
    || fail "a reversible hold with a default failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" \
    '[reversible; default: split the guide; releases 2026-10-17T10:00:00Z] Split the guide or keep one page' \
    "the reversible default and its release time did not show on the reason"
  run_captain "$home" hold sample-plain --title "Plain call" --reason "no kind given" >/dev/null \
    || fail "a hold without a kind failed"
  show=$(show_task "$home" sample-plain)
  assert_not_contains "$show" '[reversible' "a hold without a kind gained a kind"
  pass "kind and default ride on the stored reason that every hold surface decodes"
}

test_due_reversible_default_releases_with_its_record() {
  local home out show
  home=$(make_home release)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-question \
    --title "Which label size" --reason "4x6 or 4x8 labels" \
    --kind reversible --default "4x6 labels" >/dev/null || fail "could not hold the question"
  (cd "$home" && tasks-axi add sample-work "Ship the labels change" --kind ship --repo sample) >/dev/null \
    || fail "could not create the held work row"
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-work \
    --reason "Ship now or after the audit" --kind reversible --default "ship now" >/dev/null \
    || fail "could not hold the work row"
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-money \
    --title "Pay the invoice" --reason "Pay 1,449 USD or not" --kind arjun-only >/dev/null \
    || fail "could not hold the arjun-only call"

  out=$(FM_CAPTAIN_HOLD_NOW=2026-10-17T09:59:59Z run_captain "$home" release-due) \
    || fail "release-due failed before anything was due"
  assert_equals "" "$out" "release-due released a default before its 72 hours ran out"
  show=$(show_task "$home" sample-question)
  assert_contains "$show" "held: yes" "an early release-due lifted a hold"

  out=$(FM_CAPTAIN_HOLD_NOW=2026-10-17T10:00:00Z run_captain "$home" release-due) \
    || fail "release-due failed when defaults were due"
  assert_contains "$out" "released by default: sample-question 4x6 labels" \
    "the question's release line was missing"
  assert_contains "$out" "released by default: sample-work ship now" \
    "the work row's release line was missing"
  assert_not_contains "$out" "sample-money" "an arjun-only hold released itself"

  show=$(show_task "$home" sample-question)
  assert_contains "$show" "state: done" "a released question row stayed open"
  assert_contains "$show" "Resolution mode: defaulted" "the release mode was not recorded"
  assert_contains "$show" "Default release:" "the release was not labelled as a default"
  assert_contains "$show" "Option applied: 4x6 labels" "the applied option was not recorded"
  assert_not_contains "$show" "Captain decision:" "a default release read as the captain's words"

  show=$(show_task "$home" sample-work)
  assert_contains "$show" "state: queued" "a released work row was closed instead of resumed"
  assert_contains "$show" "held: no" "a released work row kept its hold"
  assert_contains "$show" "Option applied: ship now" "the work row lost its decision of record"

  show=$(show_task "$home" sample-money)
  assert_contains "$show" "held: yes" "the arjun-only hold did not stay held"
  assert_equals fleet "$(task_owner "$home" sample-work)" "a default release did not hand the work back to the fleet"
  assert_equals arjun "$(task_owner "$home" sample-money)" "a still-held call lost its captain owner"

  out=$(FM_CAPTAIN_HOLD_NOW=2026-10-20T10:00:00Z run_captain "$home" release-due) \
    || fail "a second release-due failed"
  assert_equals "" "$out" "release-due released the same holds twice"
  pass "a due reversible default releases once with a labelled record; arjun-only stays held"
}

test_rehold_keeps_or_restarts_the_release_clock() {
  local home show out
  home=$(make_home rehold)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-call \
    --title "Keep or drop the banner" --reason "keep or drop" \
    --kind reversible --default "drop it" >/dev/null || fail "could not hold the call"
  FM_CAPTAIN_HOLD_NOW=2026-10-16T10:00:00Z run_captain "$home" hold sample-call \
    --reason "keep or drop, asked again" --kind reversible --default "drop it" >/dev/null \
    || fail "could not repeat the same hold"
  show=$(show_task "$home" sample-call)
  assert_contains "$show" "releases 2026-10-17T10:00:00Z" \
    "repeating the same default moved its release time"
  FM_CAPTAIN_HOLD_NOW=2026-10-16T10:00:00Z run_captain "$home" hold sample-call \
    --reason "keep or drop, new advice" --kind reversible --default "keep it" >/dev/null \
    || fail "could not change the default"
  show=$(show_task "$home" sample-call)
  assert_contains "$show" "default: keep it; releases 2026-10-19T10:00:00Z" \
    "a new default did not restart the 72 hours"

  FM_CAPTAIN_HOLD_NOW=2026-10-16T10:00:00Z run_captain "$home" hold sample-call \
    --reason "Arjun: ask me Friday" >/dev/null || fail "could not re-hold without a kind"
  out=$(FM_CAPTAIN_HOLD_NOW=2026-12-01T00:00:00Z run_captain "$home" release-due) \
    || fail "release-due failed on a kindless hold"
  assert_equals "" "$out" "a re-hold without a kind kept self-releasing"
  show=$(show_task "$home" sample-call)
  assert_contains "$show" "held: yes" "a kindless re-hold was released"
  pass "the same default keeps its clock, a new one restarts it, and no kind never releases"
}

test_answer_before_release_wins() {
  local home out show
  home=$(make_home answered)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-call \
    --title "Pick the font" --reason "serif or sans" \
    --kind reversible --default "sans" >/dev/null || fail "could not hold the call"
  printf 'Serif, please.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain's answer was refused"
  out=$(FM_CAPTAIN_HOLD_NOW=2026-10-20T10:00:00Z run_captain "$home" release-due) \
    || fail "release-due failed after an answer"
  assert_equals "" "$out" "release-due overrode the captain's own answer"
  show=$(show_task "$home" sample-call)
  assert_contains "$show" "Serif, please." "the captain's answer was lost"
  assert_not_contains "$show" "Resolution mode: defaulted" "a default was recorded over an answer"
  pass "an answer recorded before the release time wins over the default"
}

# Whether the home's supervision predicate asks for a watcher, the switch every
# primary's turn-end guard and Claude's Stop auto-arm read.
needs_watcher() {  # <home>
  bash -c '. "$1"; if fm_supervision_needed "$2"; then echo yes; else echo no; fi' _ \
    "$ROOT/bin/fm-supervision-lib.sh" "$1/state"
}

# The watcher's hourly tick is the only caller of release-due, so a home with
# no live task must still ask for a watcher while a reversible default waits.
test_taskless_reversible_default_keeps_a_watcher_until_released() {
  local home out show
  home=$(make_home taskless)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-due \
    --title "Keep the banner" --reason "keep or drop" --kind reversible --default "drop it" >/dev/null \
    || fail "could not hold the due call"
  FM_CAPTAIN_HOLD_NOW=2026-10-16T10:00:00Z run_captain "$home" hold sample-later \
    --title "Pick the font" --reason "serif or sans" --kind reversible --default sans >/dev/null \
    || fail "could not hold the later call"
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-answered \
    --title "Pick the colour" --reason "red or blue" --kind reversible --default red >/dev/null \
    || fail "could not hold the answered call"
  printf 'Blue, please.\n' > "$home/answer.txt"
  run_captain "$home" answer sample-answered --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain's answer was refused"
  [ -z "$(find "$home/state" -name '*.meta' 2>/dev/null)" ] || fail "the fixture has a live task"
  assert_equals yes "$(needs_watcher "$home")" \
    "a task-less home holding a reversible default did not ask for a watcher"

  out=$(FM_CAPTAIN_HOLD_NOW=2026-10-17T10:00:00Z run_captain "$home" release-due) \
    || fail "release-due failed when one default was due"
  assert_equals "released by default: sample-due drop it" "$out" \
    "release-due did not release only the due default"
  show=$(show_task "$home" sample-due)
  assert_contains "$show" "Resolution mode: defaulted" "the due default left no record"
  show=$(show_task "$home" sample-later)
  assert_contains "$show" "held: yes" "a default not yet due was released"
  show=$(show_task "$home" sample-answered)
  assert_contains "$show" "Blue, please." "the captain's answer was lost"
  assert_not_contains "$show" "Resolution mode: defaulted" "a default was recorded over an answer"
  assert_equals yes "$(needs_watcher "$home")" \
    "the home stopped asking for a watcher while a default was still waiting"

  out=$(FM_CAPTAIN_HOLD_NOW=2026-10-19T10:00:00Z run_captain "$home" release-due) \
    || fail "release-due failed when the later default was due"
  assert_equals "released by default: sample-later sans" "$out" "the later default did not release"
  assert_equals no "$(needs_watcher "$home")" \
    "the home kept asking for a watcher after every default released"
  pass "a task-less reversible default keeps a watcher until it releases; not-due and answered calls stay"
}

# A held row the scan cannot read may still carry a default, so a failed read
# keeps the home supervised and reports the failure instead of clearing it.
test_unreadable_held_row_keeps_a_watcher() {
  local home real status=0
  home=$(make_home unreadable-row)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-call \
    --title "Keep the banner" --reason "keep or drop" --kind reversible --default "drop it" >/dev/null \
    || fail "could not hold the reversible call"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
case " \$* " in *" show sample-call "*) exit 1 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  FM_CAPTAIN_HOLD_NOW=2026-10-15T10:00:00Z run_captain "$home" release-due >/dev/null 2>"$home/err" \
    || status=$?
  [ "$status" -ne 0 ] || fail "release-due succeeded although a held row could not be read"
  assert_grep "sample-call could not be read" "$home/err" "the read failure was not reported"
  assert_equals yes "$(needs_watcher "$home")" "a failed read dropped the waiting default's watcher"
  pass "a held row release-due cannot read keeps the home supervised and fails the run"
}

# A hold that stops after the backend recorded its default must still leave the
# home asking for a watcher, or that default would wait for one forever.
test_interrupted_default_hold_keeps_a_watcher() {
  local home real
  home=$(make_home interrupted-hold)
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = hold ]; then "$real" "\$@"; exit 1; fi
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-call \
    --title "Keep the banner" --reason "keep or drop" --kind reversible --default "drop it" \
    >/dev/null 2>"$home/err"; then
    fail "hold succeeded although the backend reported a failure"
  fi
  assert_contains "$(show_task "$home" sample-call)" "default: drop it" "the fixture did not record the default"
  assert_equals yes "$(needs_watcher "$home")" "an interrupted hold left its default with no watcher"
  pass "a hold interrupted after its default was recorded still keeps the home supervised"
}

# Only a default can release itself, so no other hold keeps a watcher running.
test_holds_without_a_default_need_no_watcher() {
  local home
  home=$(make_home no-default-watcher)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-money \
    --title "Pay the invoice" --reason "pay or not" --kind arjun-only >/dev/null \
    || fail "could not hold the arjun-only call"
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-idea \
    --title "An idea" --reason "build it or not" --kind reversible --no-default >/dev/null \
    || fail "could not hold the no-default call"
  assert_equals no "$(needs_watcher "$home")" "a hold with no default asked for a watcher"
  pass "arjun-only and no-default holds do not keep a watcher running"
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
    "--kind reversible --default A --options A|B --recommend B" \
    "--kind reversible --default C --options A|B" \
    "--kind reversible --default A;B" \
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
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-docs \
    --title "Docs layout" --reason "Split the guide or keep one page" \
    --kind reversible --default "split the guide" --options "split the guide|keep one page" >/dev/null \
    || fail "a reversible hold with a default and choices failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" \
    '[reversible; default: split the guide; releases 2026-10-17T10:00:00Z; options: split the guide|keep one page; recommended: split the guide] Split the guide' \
    "the default did not become the recorded recommendation"
  run_captain "$home" hold sample-idea --title "An idea" --reason "Try it?" \
    --kind reversible --no-default --ask "Should we try it?" >/dev/null \
    || fail "a hold with only a question failed"
  show=$(show_task "$home" sample-idea)
  assert_contains "$show" '[reversible; ask: Should we try it?] Try it?' "an ask without choices did not ride on the reason"
  # A re-hold that passes no choices drops them with the old reason.
  run_captain "$home" hold sample-fba --reason "Count first" --kind arjun-only >/dev/null \
    || fail "the plain re-hold failed"
  show=$(show_task "$home" sample-fba)
  assert_contains "$show" '[arjun-only] Count first' "a re-hold without choices kept the old ones"
  # The default release still finds a default that carries choices.
  FM_CAPTAIN_HOLD_NOW=2026-10-18T00:00:00Z run_captain "$home" release-due > "$home/out" \
    || fail "release-due failed on a default with choices"
  assert_grep 'released by default: sample-docs split the guide' "$home/out" \
    "the default with choices did not release"
  pass "choices ride on the stored reason prefix, die with it, and keep the default release"
}

test_choices_set_choices_on_an_active_hold() {
  local home show
  home=$(make_home choice-set)
  FM_CAPTAIN_HOLD_NOW=2026-10-14T10:00:00Z run_captain "$home" hold sample-docs \
    --title "Docs layout" --reason "Split the guide (or not)" \
    --kind reversible --default build >/dev/null || fail "the reversible hold failed"
  FM_CAPTAIN_HOLD_NOW=2026-10-15T10:00:00Z run_captain "$home" choices sample-docs \
    --options "build|skip" --ask "Build it?" >/dev/null || fail "choices on a default hold failed"
  show=$(show_task "$home" sample-docs)
  assert_contains "$show" \
    '[reversible; default: build; releases 2026-10-17T10:00:00Z; options: build|skip; recommended: build; ask: Build it?] Split the guide (or not)' \
    "choices did not keep the reason, default and release time"
  run_captain "$home" choices sample-docs --options "build|wait" >/dev/null || fail "replacing choices failed"
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
  pass "choices sets the choices on an active hold and keeps its reason, default, date and question"
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
test_reversible_hold_names_its_default
test_hold_records_the_captain_as_owner_and_release_hands_back
test_kind_prefix_shows_on_every_hold_reason
test_due_reversible_default_releases_with_its_record
test_rehold_keeps_or_restarts_the_release_clock
test_answer_before_release_wins
test_taskless_reversible_default_keeps_a_watcher_until_released
test_unreadable_held_row_keeps_a_watcher
test_interrupted_default_hold_keeps_a_watcher
test_holds_without_a_default_need_no_watcher
