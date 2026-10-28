#!/usr/bin/env bash
# Behavior tests for bin/fm-noticed.sh: a noticed problem or an idea becomes a
# captain hold that never dispatches, a duplicate attaches evidence instead of
# filing twice, a finished task's lines are collected, the Monday top 3 is
# recorded once, and the wake drain shows each unseen item until it is marked
# shown.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTICED="$ROOT/bin/fm-noticed.sh"
TMP_ROOT=$(fm_test_tmproot fm-noticed)

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

noticed() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_NOTICED_NOW=2026-10-27 "$NOTICED" "$@"
}

tasks() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

test_noticed_is_a_captain_hold_that_never_dispatches() {
  local home out show
  home=$(make_home file)
  out=$(noticed "$home" file noticed canary-red --title "Packet canary red twice" \
    --why "the Monday packet may be wrong" --from fix-labels-1027 --repo business) \
    || fail "file refused a valid item: $out"
  assert_equals "filed: noticed-canary-red" "$out" "file did not report the new item"
  show=$(tasks "$home" show noticed-canary-red --full)
  assert_contains "$show" "kind: noticed" "the item is not tagged noticed"
  assert_contains "$show" "held: yes" "the item is not held for the captain"
  assert_contains "$show" "[reversible]" "the item is not a reversible call"
  assert_contains "$show" "Why it may matter: the Monday packet may be wrong" "the why was not kept"
  assert_contains "$(tasks "$home" ready)" "ready: 0" "a noticed item became dispatchable"
  assert_equals "noticed-canary-red	noticed	Packet canary red twice" "$(noticed "$home" unseen)" \
    "the noticed item is not on the unseen list"
  pass "a noticed problem is a captain hold that never dispatches and waits to be shown"
}

test_a_duplicate_attaches_evidence() {
  local home out show
  home=$(make_home duplicate)
  noticed "$home" file noticed canary-red --title "Packet canary red" --why "packet may be wrong" \
    --from t1 >/dev/null || fail "first file failed"
  out=$(noticed "$home" file noticed canary-red --title "Packet canary red again" --why "still red" \
    --from t2 --evidence "canary run 10-27 exit 2") || fail "second file failed: $out"
  assert_equals "matched: noticed-canary-red" "$out" "a duplicate was not matched"
  show=$(tasks "$home" show noticed-canary-red --full)
  assert_contains "$show" "Seen again 2026-10-27 by t2: canary run 10-27 exit 2" "the new evidence was not attached"
  assert_equals 1 "$(noticed "$home" unseen | wc -l | tr -d ' ')" "a duplicate was listed twice"
  pass "a duplicate attaches its evidence to the open item"
}

test_closed_items_come_back_or_stay_answered() {
  local home out
  home=$(make_home closed)
  noticed "$home" file noticed printer-down --title "Printer offline" --why "labels stall" --from t1 >/dev/null
  noticed "$home" shown noticed-printer-down >/dev/null
  tasks "$home" "done" noticed-printer-down >/dev/null || fail "could not close the fixture"
  out=$(noticed "$home" file noticed printer-down --title "Printer offline again" --why "labels stall" --from t2)
  assert_equals "reopened: noticed-printer-down" "$out" "a recurring problem was not reopened"
  assert_contains "$(tasks "$home" show noticed-printer-down)" "held: yes" "the reopened item is not held"
  assert_contains "$(noticed "$home" unseen)" "noticed-printer-down" "the reopened item is not shown again"

  noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t1 >/dev/null
  tasks "$home" "done" idea-bundle-slow >/dev/null || fail "could not close the idea fixture"
  out=$(noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t3)
  assert_equals "skipped: idea-bundle-slow (answered earlier)" "$out" "an answered idea was asked again"
  pass "a fixed problem that recurs comes back, and an answered idea is never re-asked"
}

test_refusals() {
  local home
  home=$(make_home refusals)
  noticed "$home" file idea x --title a --why b --from nova >/dev/null 2>&1 \
    && fail "a Nova item was filed into this backlog"
  noticed "$home" file other x --title a --why b >/dev/null 2>&1 && fail "an unknown kind was accepted"
  noticed "$home" file idea Bad_Slug --title a --why b >/dev/null 2>&1 && fail "a bad slug was accepted"
  noticed "$home" file idea ok --title a --why '' >/dev/null 2>&1 && fail "an empty why was accepted"
  assert_equals "" "$(tasks "$home" list --kind idea --fields created | grep -E '^  idea-' || true)" \
    "a refused call left a row"
  pass "Nova items, unknown kinds, bad slugs and empty reasons are refused"
}

test_top3_is_recorded_once_and_shown_until_marked() {
  local home out
  home=$(make_home top3)
  noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t1 >/dev/null
  noticed "$home" file noticed canary-red --title "Canary red" --why "packet" --from t1 >/dev/null
  assert_equals "" "$(noticed "$home" unseen | grep idea- || true)" "an idea was shown before the ranking"
  out=$(noticed "$home" top3 idea-bundle-slow noticed-canary-red idea-missing)
  assert_equals 1 "$?" "top3 accepted a non-idea"
  assert_contains "$out" "top: idea-bundle-slow" "the idea was not recorded"
  assert_contains "$out" "refused: noticed-canary-red (not an idea)" "a noticed item was ranked"
  assert_contains "$out" "refused: idea-missing (not an open idea)" "a missing idea was ranked"
  assert_contains "$(noticed "$home" top3 idea-bundle-slow)" "already in an earlier top 3" \
    "an idea was picked twice"
  assert_contains "$(noticed "$home" unseen)" "idea-bundle-slow	top idea	Bundle slow movers" \
    "the pick is not on the unseen list"
  assert_equals "shown: idea-bundle-slow" "$(noticed "$home" shown idea-bundle-slow)" "shown did not mark the pick"
  assert_equals "noticed-canary-red	noticed	Canary red" "$(noticed "$home" unseen)" "shown removed the wrong item"
  pass "the top 3 takes open ideas once, and each stays unseen until marked shown"
}

test_collect_reads_the_report_then_notes() {
  local home out
  home=$(make_home collect)
  mkdir -p "$home/data/scout-1" "$home/data/ship-1" "$home/data/quiet-1"
  printf '# Report\n\n## Noticed and ideas\n- Noticed: none\n- **Idea:** cache the fee table weekly\n' \
    > "$home/data/scout-1/report.md"
  printf 'Noticed: Thor printer offline since Monday, labels stall\n' > "$home/data/scout-1/notes.md"
  out=$(noticed "$home" collect scout-1)
  assert_contains "$out" "Noticed: Thor printer offline since Monday, labels stall (scout-1/notes.md)" \
    "a notes line was not collected after a none in the report"
  assert_contains "$out" "Idea: cache the fee table weekly (scout-1/report.md)" "the report's idea was not collected"
  printf 'Idea: one\nIdea: two\n' > "$home/data/ship-1/notes.md"
  assert_equals "Idea: one (ship-1/notes.md)" "$(noticed "$home" collect ship-1)" "more than one idea was collected"
  assert_equals "" "$(noticed "$home" collect quiet-1)" "a task with nothing left printed something"
  pass "collect takes at most one noticed and one idea, from the report then the notes"
}

test_the_drain_shows_unseen_items() {
  local home drain
  home=$(make_home drain)
  printf 'done: finished\n' > "$home/state/some-task.status"
  drain=$(run_drain "$home") || fail "the drain failed with nothing filed"
  assert_not_contains "$drain" "NOTICED" "the drain printed an empty NOTICED section"
  noticed "$home" file noticed canary-red --title "Canary red" --why "packet" --from t1 >/dev/null
  drain=$(run_drain "$home") || fail "the drain failed with an unseen item"
  assert_contains "$drain" "NOTICED (filed for the captain, not yet shown to him):" "the section is missing"
  assert_contains "$drain" "noticed-canary-red (noticed): Canary red" "the item is missing from the section"
  assert_contains "$drain" "bin/fm-noticed.sh shown <id>" "the section does not say how to mark it shown"
  noticed "$home" shown noticed-canary-red >/dev/null
  drain=$(run_drain "$home") || fail "the drain failed after marking"
  assert_not_contains "$drain" "NOTICED" "a shown item was presented again"
  pass "the wake drain shows each unseen item until it is marked shown"
}

test_noticed_is_a_captain_hold_that_never_dispatches
test_a_duplicate_attaches_evidence
test_closed_items_come_back_or_stay_answered
test_refusals
test_top3_is_recorded_once_and_shown_until_marked
test_collect_reads_the_report_then_notes
test_the_drain_shows_unseen_items
