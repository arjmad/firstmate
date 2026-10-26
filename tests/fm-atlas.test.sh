#!/usr/bin/env bash
# Behavior tests for bin/fm-atlas.sh: an Atlas build's seven ideas become
# ordinary captain holds bearings shows as cards, an answered idea is never
# asked again, a "do it" pick names the fleet task to file, and the keep test
# reads the picks and their measured results.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATLAS="$ROOT/bin/fm-atlas.sh"
TMP_ROOT=$(fm_test_tmproot fm-atlas)

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

# A build whose seven slugs are <prefix>-1 .. <prefix>-7.
make_build() {  # <file> <built_at> <prefix>
  jq -n --arg at "$2" --arg p "$3" '{schema: "atlas.v1", built_at: $at, ideas: [range(1; 8) as $n | {
    id: "A\($n)", slug: "\($p)-\($n)", box: "channels", tag: "FIX", text: "Idea \($p) \($n)",
    estimate: "$\($n)00/week", evidence: "Sales monitor 10-26: evidence \($n).", repo: "business",
    brief: "Start work on idea \($p) \($n)"}]}' > "$1"
}

atlas() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_ATLAS_NOW=2026-10-26T12:00:00Z "$ATLAS" "$@"
}

answer() {  # <home> <task-id> <words>
  printf '%s\n' "$3" > "$1/answer.txt"
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" "$ROOT/bin/fm-captain-hold.sh" answer "$2" --decision-file "$1/answer.txt" >/dev/null
}

show_task() {  # <home> <id>
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" show "$2" --full
}

test_file_holds_each_idea_for_the_captain() {
  local home out show
  home=$(make_home file)
  make_build "$home/atlas.json" "2026-10-26 13:00Z" one
  out=$(atlas "$home" file "$home/atlas.json" --board http://board.example/session/1) \
    || fail "file refused a valid build: $out"
  assert_equals 7 "$(grep -c '^held: atlas-one-' <<<"$out")" "not every idea was held"
  show=$(show_task "$home" atlas-one-2)
  assert_contains "$show" "held: yes" "the idea is not held for the captain"
  assert_contains "$show" "Idea one 2" "the card is not titled with the idea"
  assert_contains "$show" "repo: business" "the idea's repo was not kept"
  assert_contains "$show" "Atlas A2, \$200/week: Sales monitor 10-26: evidence 2. Do it: Start work on idea one 2" \
    "the hold reason does not carry the rank, estimate, evidence and brief"
  assert_contains "$show" "[reversible]" "the idea is not a reversible call"
  atlas "$home" latest | jq -e '.board == "http://board.example/session/1" and .built_at == "2026-10-26 13:00Z"' >/dev/null \
    || fail "latest does not name the build's board"
  pass "file holds each of the seven ideas for the captain and records the board"
}

test_refiling_and_answered_ideas() {
  local home out
  home=$(make_home refile)
  make_build "$home/atlas.json" "2026-10-26 13:00Z" one
  atlas "$home" file "$home/atlas.json" >/dev/null || fail "the first file failed"
  answer "$home" atlas-one-1 "drop"
  out=$(atlas "$home" file "$home/atlas.json") || fail "refiling the same build failed: $out"
  assert_contains "$out" "skipped: atlas-one-1 (answered in an earlier build)" "an answered idea was asked again"
  assert_contains "$out" "open: atlas-one-2" "a still-open idea was not reported open"
  atlas "$home" pick atlas-one-3 drop >/dev/null || fail "pick refused"
  make_build "$home/next.json" "2026-11-02 13:00Z" one
  out=$(atlas "$home" file "$home/next.json")
  assert_contains "$out" "skipped: atlas-one-3 (answered in an earlier build)" "a picked idea was asked again"
  pass "refiling keeps open ideas held and never asks an answered idea again"
}

test_file_refuses_a_bad_build() {
  local home
  home=$(make_home refuse)
  make_build "$home/atlas.json" "2026-10-26 13:00Z" one
  jq '.ideas |= .[:6]' "$home/atlas.json" > "$home/six.json"
  jq '.ideas[1].id = "A9"' "$home/atlas.json" > "$home/rank.json"
  jq '.ideas[2].brief = ""' "$home/atlas.json" > "$home/brief.json"
  for bad in six rank brief; do
    if atlas "$home" file "$home/$bad.json" >/dev/null 2>&1; then
      fail "file accepted a build with a $bad problem"
    fi
  done
  [ ! -e "$home/state/atlas/record.json" ] || fail "a refused build was recorded"
  pass "file refuses a build that is not seven ranked, complete ideas"
}

test_pick_names_the_fleet_task() {
  local home out
  home=$(make_home pick)
  make_build "$home/atlas.json" "2026-10-26 13:00Z" one
  atlas "$home" file "$home/atlas.json" >/dev/null
  out=$(atlas "$home" pick atlas-one-4 do-it) || fail "pick refused"
  assert_contains "$out" "picked: atlas-one-4 do-it" "the pick was not confirmed"
  assert_contains "$out" "dispatch: business	Start work on idea one 4" "do-it did not name the fleet task"
  out=$(atlas "$home" pick atlas-one-5 drop)
  case "$out" in *dispatch:*) fail "a drop named a fleet task" ;; esac
  if atlas "$home" pick atlas-one-6 not-now >/dev/null 2>&1; then
    fail "pick accepted an answer outside do-it and drop"
  fi
  if atlas "$home" pick sales-monitor do-it >/dev/null 2>&1; then
    fail "pick accepted a task that is no Atlas idea"
  fi
  pass "a do-it pick names the fleet task to file and a drop names none"
}

test_keep_test_reads_picks_and_results() {
  local home
  home=$(make_home keep)
  make_build "$home/one.json" "2026-10-26 13:00Z" one
  make_build "$home/two.json" "2026-11-02 13:00Z" two
  make_build "$home/three.json" "2026-11-09 13:00Z" three
  atlas "$home" file "$home/one.json" >/dev/null
  [ "$(atlas "$home" keep-test | jq -r .verdict)" = open ] || fail "one build with no picks is not open"
  atlas "$home" pick atlas-one-1 do-it >/dev/null
  atlas "$home" file "$home/two.json" >/dev/null
  atlas "$home" keep-test | jq -e '.verdict == "open" and .unanswered == 13' >/dev/null \
    || fail "a second build with unanswered ideas already reads as decided"
  atlas "$home" pick atlas-two-2 do-it >/dev/null
  [ "$(atlas "$home" keep-test | jq -r .verdict)" = open ] || fail "two unmeasured picks are not open"
  atlas "$home" measure atlas-one-1 --gain no --result "no change in a week" >/dev/null \
    || fail "measure refused the task id"
  atlas "$home" measure two-2 --gain yes --result "\$300/week back" >/dev/null || fail "measure refused the slug"
  atlas "$home" file "$home/three.json" >/dev/null
  atlas "$home" pick atlas-three-3 do-it >/dev/null
  atlas "$home" keep-test | jq -e '.verdict == "met" and .measured_gains == 1 and (.picked | length) == 2
    and (.picked | map(.slug) | sort) == ["one-1", "two-2"]' >/dev/null \
    || fail "two picks from the first two builds with one gain is not met, or a third build's pick counted"
  if atlas "$home" measure one-5 --gain yes --result "x" >/dev/null 2>&1; then
    fail "measure accepted an idea nobody picked"
  fi
  pass "the keep test counts the first two builds' picks and their measured gains"
}

test_keep_test_is_not_met_once_every_idea_is_answered() {
  local home n
  home=$(make_home notmet)
  make_build "$home/one.json" "2026-10-26 13:00Z" one
  make_build "$home/two.json" "2026-11-02 13:00Z" two
  atlas "$home" file "$home/one.json" >/dev/null
  atlas "$home" file "$home/two.json" >/dev/null
  atlas "$home" pick atlas-one-1 do-it >/dev/null
  for n in 2 3 4 5 6 7; do atlas "$home" pick "atlas-one-$n" drop >/dev/null; done
  for n in 1 2 3 4 5 6 7; do atlas "$home" pick "atlas-two-$n" drop >/dev/null; done
  atlas "$home" keep-test | jq -e '.verdict == "not-met" and .unanswered == 0' >/dev/null \
    || fail "two builds fully answered with one pick is not not-met"
  pass "the keep test is not met only once both builds are fully answered with fewer than two picks"
}

test_an_idea_belongs_to_the_build_that_first_offered_it() {
  local home out
  home=$(make_home first)
  make_build "$home/one.json" "2026-10-26 13:00Z" one
  make_build "$home/two.json" "2026-11-02 13:00Z" one
  jq '.ideas[0].brief = "A reworded brief" | .ideas[0].repo = "fleet" | .ideas[0].text = "Reworded"' \
    "$home/two.json" > "$home/two.tmp" && mv "$home/two.tmp" "$home/two.json"
  atlas "$home" file "$home/one.json" --board http://board.example/session/1 >/dev/null
  atlas "$home" file "$home/two.json" --board http://board.example/session/2 >/dev/null
  out=$(atlas "$home" pick atlas-one-1 do-it)
  assert_contains "$out" "dispatch: business	Start work on idea one 1" "the pick did not dispatch the brief on the card"
  atlas "$home" keep-test | jq -e '.picked[0].built_at == "2026-10-26 13:00Z"' >/dev/null \
    || fail "the pick was not credited to the build that first offered the idea"
  # Refiling the first build keeps the build order and, without --board, its link.
  atlas "$home" file "$home/one.json" >/dev/null
  jq -e '[.builds[].built_at] == ["2026-10-26 13:00Z", "2026-11-02 13:00Z"] and .builds[0].board == "http://board.example/session/1"' \
    "$home/state/atlas/record.json" >/dev/null || fail "refiling a build reordered the builds or lost its board link"
  if atlas "$home" file "$home/one.json" --board file:///tmp/atlas.html >/dev/null 2>&1; then
    fail "file accepted a board link bearings would refuse"
  fi
  pass "an idea keeps its first build's wording, brief and credit, and refiling keeps order and link"
}

test_file_holds_each_idea_for_the_captain
test_refiling_and_answered_ideas
test_file_refuses_a_bad_build
test_pick_names_the_fleet_task
test_keep_test_reads_picks_and_results
test_keep_test_is_not_met_once_every_idea_is_answered
test_an_idea_belongs_to_the_build_that_first_offered_it
