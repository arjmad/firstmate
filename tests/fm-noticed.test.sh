#!/usr/bin/env bash
# Behavior tests for bin/fm-noticed.sh: a noticed problem is the fleet's own
# work unless --call names the captain call it needs, an idea or a --call item
# becomes a captain hold that never dispatches, a duplicate attaches evidence instead of
# filing twice, a finished task's lines are collected, every unseen item waits for the Monday
# triage, and the wake drain shows only an urgent (--now) item, until it is marked shown.
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
    --why "the Monday packet may be wrong" --from fix-labels-1027 --repo business --call ruling) \
    || fail "file refused a valid item: $out"
  assert_equals "filed: noticed-canary-red" "$out" "file did not report the new item"
  show=$(tasks "$home" show noticed-canary-red --full)
  assert_contains "$show" "kind: noticed" "the item is not tagged noticed"
  assert_contains "$show" "held: yes" "the item is not held for the captain"
  assert_contains "$show" "[reversible]" "the item is not a reversible call"
  assert_contains "$show" "(call: ruling)" "the hold does not name the call it needs"
  assert_contains "$show" "Why it may matter: the Monday packet may be wrong" "the why was not kept"
  assert_contains "$(tasks "$home" ready)" "ready: 0" "a noticed item became dispatchable"
  assert_equals "noticed-canary-red	noticed	Packet canary red twice" "$(noticed "$home" unseen)" \
    "the noticed item is not on the unseen list"
  pass "a noticed problem filed --call is a captain hold that never dispatches and waits to be shown"
}

test_a_duplicate_attaches_evidence() {
  local home out show long
  home=$(make_home duplicate)
  long="packet may be wrong: $(printf 'evidence %.0s' $(seq 1 80))end-of-first-why"
  noticed "$home" file noticed canary-red --title "Packet canary red" --why "$long" \
    --from t1 --call ruling >/dev/null || fail "first file failed"
  out=$(noticed "$home" file noticed canary-red --title "Packet canary red again" --why "still red" \
    --from t2 --evidence "canary run 10-27 exit 2") || fail "second file failed: $out"
  assert_equals "matched: noticed-canary-red" "$out" "a duplicate was not matched"
  show=$(tasks "$home" show noticed-canary-red --full)
  assert_contains "$show" "Seen again 2026-10-27 by t2: canary run 10-27 exit 2" "the new evidence was not attached"
  assert_contains "$(printf '%s\n' "$show" | grep '^  body: ')" "end-of-first-why" \
    "attaching evidence cut the earlier body short"
  assert_equals 1 "$(noticed "$home" unseen | wc -l | tr -d ' ')" "a duplicate was listed twice"
  pass "a duplicate attaches its evidence to the open item"
}

test_closed_items_come_back_or_stay_answered() {
  local home out
  home=$(make_home closed)
  noticed "$home" file noticed printer-down --title "Printer offline" --why "labels stall" --from t1 --call ruling >/dev/null
  noticed "$home" shown noticed-printer-down >/dev/null
  tasks "$home" "done" noticed-printer-down >/dev/null || fail "could not close the fixture"
  out=$(noticed "$home" file noticed printer-down --title "Printer offline again" --why "labels stall" --from t2 --call ruling)
  assert_equals "reopened: noticed-printer-down" "$out" "a recurring problem was not reopened"
  assert_contains "$(tasks "$home" show noticed-printer-down)" "held: yes" "the reopened item is not held"
  assert_contains "$(noticed "$home" unseen)" "noticed-printer-down" "the reopened item is not shown again"

  noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t1 >/dev/null
  tasks "$home" "done" idea-bundle-slow >/dev/null || fail "could not close the idea fixture"
  out=$(noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t3)
  assert_equals "skipped: idea-bundle-slow (answered earlier)" "$out" "an answered idea was asked again"

  # Done retention archives closed rows out of the backlog; both rules hold after it.
  noticed "$home" file noticed printer-down --title "Printer offline" --why "labels stall" --from t4 >/dev/null
  tasks "$home" "done" noticed-printer-down >/dev/null || fail "could not close the fixture again"
  printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 0' > "$home/.tasks.toml"
  tasks "$home" prune >/dev/null || fail "could not archive the closed fixtures"
  tasks "$home" show idea-bundle-slow >/dev/null 2>&1 && fail "the fixture was not archived"
  out=$(noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t5)
  assert_equals "skipped: idea-bundle-slow (answered earlier)" "$out" "an archived answered idea was asked again"
  out=$(noticed "$home" file noticed printer-down --title "Printer offline" --why "labels stall" --from t6)
  assert_equals "reopened: noticed-printer-down" "$out" "an archived recurring problem was not brought back"
  assert_contains "$(tasks "$home" show noticed-printer-down --full)" "its record is in the Done archive" \
    "the refiled problem does not point at its archived record"
  pass "a fixed problem that recurs comes back, and an answered idea is never re-asked, archived or not"
}

test_refusals() {
  local home
  home=$(make_home refusals)
  noticed "$home" file idea x --title a --why b --from nova >/dev/null 2>&1 \
    && fail "a Nova item was filed into this backlog"
  noticed "$home" file idea x --title a --why b --from "Nova (Sapna)" >/dev/null 2>&1 \
    && fail "a Nova item with a longer name was filed"
  noticed "$home" file idea x --title a --why b --from sapna-mail-1027 >/dev/null 2>&1 \
    && fail "a Sapna task's item was filed"
  noticed "$home" file other x --title a --why b >/dev/null 2>&1 && fail "an unknown kind was accepted"
  noticed "$home" file idea Bad_Slug --title a --why b >/dev/null 2>&1 && fail "a bad slug was accepted"
  noticed "$home" file idea ok --title a --why '' >/dev/null 2>&1 && fail "an empty why was accepted"
  noticed "$home" file noticed ok --title a --why b --call later >/dev/null 2>&1 && fail "an unknown call kind was accepted"
  noticed "$home" file noticed ok --title a --why b --call >/dev/null 2>&1 && fail "an empty call kind was accepted"
  noticed "$home" file idea ok --title a --why b --call ruling >/dev/null 2>&1 && fail "an idea took --call"
  noticed "$home" file noticed ok --title a --why b --call ruling --routine >/dev/null 2>&1 \
    && fail "--call was accepted beside --routine"
  assert_equals "" "$(tasks "$home" list --kind idea --fields created | grep -E '^  idea-' || true)" \
    "a refused call left a row"
  assert_equals "" "$(tasks "$home" list --kind noticed --fields created | grep -E '^  noticed-' || true)" \
    "a refused --call left a row"
  pass "Nova items, unknown kinds, bad slugs, empty reasons and bad --call uses are refused"
}

test_collect_reads_the_report_then_notes() {
  local home out
  home=$(make_home collect)
  mkdir -p "$home/data/scout-1" "$home/data/ship-1" "$home/data/quiet-1"
  printf '# Report\n\n## Noticed and ideas\n- Noticed: none\n- **Idea:** cache the fee table weekly\n' \
    > "$home/data/scout-1/report.md"
  printf 'Noticed: a quoted research note\nIdea: an idea jotted mid-task\n' > "$home/data/scout-1/notes.md"
  out=$(noticed "$home" collect scout-1)
  assert_equals "Idea: cache the fee table weekly (scout-1/report.md)" "$out" \
    "the report's none did not settle Noticed, or its idea was not the one collected"
  printf 'Noticed: jotted early\nIdea: one\nwork notes\nNoticed: Thor printer offline, labels stall\nIdea: two\n' \
    > "$home/data/ship-1/notes.md"
  out=$(noticed "$home" collect ship-1)
  assert_equals "Noticed: Thor printer offline, labels stall (ship-1/notes.md)
Idea: two (ship-1/notes.md)" "$out" "the end-of-task lines were not the ones collected"
  assert_equals "" "$(noticed "$home" collect quiet-1)" "a task with nothing left printed something"
  noticed "$home" collect .. >/dev/null 2>&1 && fail "collect read outside the task's own records"
  pass "collect takes the end-of-task noticed and idea lines, and a report's none settles its label"
}

test_close_settles_an_item_and_list_keeps_answered_ones() {
  local home out
  home=$(make_home close)
  noticed "$home" file noticed canary-red --title "Canary red" --why "packet" --from t1 >/dev/null
  noticed "$home" file noticed printer-down --title "Printer offline" --why "labels" --from t1 --call ruling >/dev/null
  out=$(noticed "$home" close noticed-canary-red --evidence "business PR 431 fixed the packet check")
  assert_equals "closed: noticed-canary-red" "$out" "close did not report the item"
  assert_contains "$(tasks "$home" show noticed-canary-red --full)" "Settled 2026-10-27: business PR 431 fixed" \
    "the evidence was not recorded"
  assert_contains "$(tasks "$home" show noticed-canary-red)" "state: done" "the item is still open"
  assert_equals "noticed-printer-down	noticed	Printer offline" "$(noticed "$home" unseen)" \
    "a closed item stayed on the unseen list"
  printf 'Fix it\n' > "$home/answer.txt"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" answer noticed-printer-down \
    --decision-file "$home/answer.txt" --release >/dev/null || fail "could not answer the fixture"
  assert_contains "$(noticed "$home" list noticed)" "noticed-printer-down" "an answered, released item left the list"
  pass "close settles an item with its evidence and unseen entry, and list keeps answered items"
}

test_a_fix_on_its_own_waits_for_the_triage() {
  local home out drain
  home=$(make_home fixed)
  noticed "$home" file noticed stale-doc --title "Stale setup doc" --why "new hosts misconfigure" --from t1 >/dev/null
  out=$(noticed "$home" close noticed-stale-doc --evidence "rewrote the setup steps" --fixed \
    --pr https://github.com/o/r/pull/7) || fail "close --fixed refused a noticed item: $out"
  assert_equals "closed: noticed-stale-doc" "$out" "close --fixed did not report the item"
  assert_contains "$(tasks "$home" show noticed-stale-doc --full)" \
    "Settled 2026-10-27: rewrote the setup steps (https://github.com/o/r/pull/7) Fixed by firstmate on its own." \
    "the fix, its PR and who fixed it were not recorded"
  assert_equals "noticed-stale-doc	fixed	Stale setup doc - rewrote the setup steps (https://github.com/o/r/pull/7)" \
    "$(noticed "$home" unseen)" "the fix is not listed for the Monday triage"
  drain=$(run_drain "$home") || fail "the drain failed with a fix listed"
  assert_not_contains "$drain" "NOTICED" "a fix on its own interrupted the captain"
  assert_equals "shown: noticed-stale-doc" "$(noticed "$home" shown noticed-stale-doc)" "the triage could not mark the fix"
  assert_equals "" "$(noticed "$home" unseen)" "a reported fix stayed listed"

  noticed "$home" file noticed stale-doc --title "Stale setup doc" --why "still wrong" --from t2 >/dev/null
  noticed "$home" close noticed-stale-doc --evidence "second fix" --fixed --pr https://github.com/o/r/pull/8 >/dev/null
  out=$(noticed "$home" file noticed stale-doc --title "Stale setup doc" --why "broken again" --from t3 --call ruling)
  assert_equals "reopened: noticed-stale-doc" "$out" "a problem back after a fix on its own was not reopened"
  assert_equals "noticed-stale-doc	noticed	Stale setup doc" "$(noticed "$home" unseen)" \
    "a problem back after its fix is still reported as fixed"

  noticed "$home" file noticed refunds --title "Refunds failing" --why "customers unpaid" --from t1 --now >/dev/null
  noticed "$home" close noticed-refunds --evidence "retried the refunds" --fixed --pr https://github.com/o/r/pull/9 >/dev/null
  assert_contains "$(noticed "$home" unseen)" "noticed-refunds	now	Refunds failing" \
    "closing an urgent item before he was told dropped it from the drain"

  noticed "$home" file noticed printer --title "Printer offline" --why "labels" --from t1 >/dev/null
  noticed "$home" close noticed-printer --evidence x --fixed >/dev/null 2>&1 && fail "a fix on its own was recorded without its PR"
  assert_contains "$(tasks "$home" show noticed-printer)" "state: queued" "a refused close still closed the item"
  noticed "$home" file idea faster --title a --why b --from t1 >/dev/null
  noticed "$home" close idea-faster --evidence x --fixed --pr https://github.com/o/r/pull/1 >/dev/null 2>&1 \
    && fail "an idea was closed as fixed on its own"
  assert_contains "$(tasks "$home" show idea-faster)" "state: queued" "a refused close still closed the idea"
  pass "a fix firstmate makes on its own needs its PR, waits for the Monday triage, gives way to a recurrence, and never hides an untold urgent item"
}

# Rule 1 of 2026-11-11, enforced as the default on 2026-11-17: a noticed item
# is the fleet's own work unless --call names the call it needs from him, and
# reaches him only in the Monday "Handled for you" list once fixed or dropped.
test_a_routine_item_is_never_held_for_him() {
  local home out show
  home=$(make_home routine)
  out=$(noticed "$home" file noticed lint-drift --title "Lint config drifted" --why "CI may pass bad code" \
    --from t1 --repo firstmate) || fail "file refused a noticed item: $out"
  assert_equals "filed: noticed-lint-drift" "$out" "file did not report the routine item"
  show=$(tasks "$home" show noticed-lint-drift --full)
  assert_not_contains "$show" "held: yes" "a noticed item with no --call was held for the captain"
  assert_contains "$show" "Routine: firstmate fixes or drops this on its own." "the routine item does not say so"
  assert_equals fleet "$(tasks "$home" owner noticed-lint-drift)" "a routine item is not the fleet's"
  assert_equals "" "$(noticed "$home" unseen)" "a routine item waits to be shown before it is handled"
  out=$(noticed "$home" file noticed lint-drift --title "Lint config drifted" --why "seen again" --from t2)
  assert_equals "matched: noticed-lint-drift" "$out" "a routine item filed again was not matched"
  assert_not_contains "$(tasks "$home" show noticed-lint-drift --full)" "held: yes" "a routine item filed again was held"
  # A ship's teardown may close the row before firstmate records the fix.
  tasks "$home" "done" noticed-lint-drift >/dev/null || fail "could not close the routine row"
  out=$(noticed "$home" close noticed-lint-drift --evidence "pinned the lint config" --fixed \
    --pr https://github.com/o/r/pull/3) || fail "close --fixed refused a row already closed: $out"
  assert_equals "noticed-lint-drift	fixed	Lint config drifted - pinned the lint config (https://github.com/o/r/pull/3)" \
    "$(noticed "$home" unseen)" "a routine fix is not listed for the Monday triage"
  noticed "$home" shown noticed-lint-drift >/dev/null
  # Older callers still pass --routine; it files the same routine row.
  out=$(noticed "$home" file noticed dead-link --title "Dead doc link" --why "readers get lost" --from t1 --routine) \
    || fail "file refused the old --routine flag: $out"
  assert_equals "filed: noticed-dead-link" "$out" "file --routine did not report the item"
  assert_not_contains "$(tasks "$home" show noticed-dead-link --full)" "held: yes" "file --routine held the item"
  assert_equals fleet "$(tasks "$home" owner noticed-dead-link)" "file --routine did not give the item to the fleet"
  out=$(noticed "$home" close noticed-dead-link --evidence "the page was retired on purpose" --dropped) \
    || fail "close --dropped refused: $out"
  assert_equals "noticed-dead-link	dropped	Dead doc link - the page was retired on purpose" \
    "$(noticed "$home" unseen)" "a drop on its own is not listed for the Monday triage"
  assert_contains "$(tasks "$home" show noticed-dead-link --full)" "Dropped by firstmate on its own." "the drop was not recorded"
  noticed "$home" close noticed-dead-link --evidence x --fixed --dropped --pr https://github.com/o/r/pull/4 >/dev/null 2>&1 \
    && fail "close accepted --fixed with --dropped"
  noticed "$home" file idea quicker --title a --why b --from t1 --routine >/dev/null 2>&1 \
    && fail "an idea was filed routine"
  out=$(noticed "$home" file noticed dead-link --title "Dead doc link" --why "back" --from t3)
  assert_equals "reopened: noticed-dead-link" "$out" "a routine item back after its drop was not reopened"
  assert_not_contains "$(tasks "$home" show noticed-dead-link --full)" "held: yes" "a reopened routine item was held"
  assert_equals "" "$(noticed "$home" unseen)" "a reopened routine item still reads as dropped"
  noticed "$home" close noticed-dead-link --evidence "settled" >/dev/null
  out=$(noticed "$home" file noticed dead-link --title "Dead doc link" --why "now it needs a ruling" --from t4 --call ruling)
  assert_equals "reopened: noticed-dead-link" "$out" "a routine item back with --call was not reopened"
  assert_contains "$(tasks "$home" show noticed-dead-link --full)" "(call: ruling)" "a routine item back with --call was not held"
  assert_contains "$(noticed "$home" unseen)" "noticed-dead-link	noticed	Dead doc link" \
    "a routine item back with --call does not wait for the Monday triage"
  assert_contains "$(tasks "$home" show noticed-dead-link --full)" "Held for the captain (call: ruling)." \
    "a routine item back with --call does not say in its body that it is held now"
  # An open routine item that turns out to need his call is held when filed again with --call.
  noticed "$home" file noticed slow-sync --title "Slow sync" --why "lag" --from t1 >/dev/null
  out=$(noticed "$home" file noticed slow-sync --title "Slow sync" --why "needs new machinery" --from t2 --call machinery)
  assert_equals "matched: noticed-slow-sync" "$out" "an open routine item filed with --call was not matched"
  show=$(tasks "$home" show noticed-slow-sync --full)
  assert_contains "$show" "held: yes" "an open routine item filed with --call was not held"
  assert_contains "$show" "(call: machinery)" "the new hold does not name its call"
  assert_contains "$show" "Held for the captain 2026-10-27 (call: machinery)." "the body does not say the row is held now"
  assert_contains "$(noticed "$home" unseen)" "noticed-slow-sync	noticed	Slow sync" \
    "an open routine item held with --call does not wait for the Monday triage"
  noticed "$home" file noticed held-once --title "Held once" --why "first" --from t1 --call retire >/dev/null
  noticed "$home" close noticed-held-once --evidence "settled" >/dev/null
  out=$(noticed "$home" file noticed held-once --title "Held once" --why "back" --from t2) \
    || fail "a held item back as routine could not be reopened: $out"
  assert_equals "reopened: noticed-held-once (lifted its earlier captain hold)" "$out" \
    "a held item back as routine does not say its old hold was lifted"
  assert_contains "$(tasks "$home" show noticed-held-once --full)" "Its earlier captain hold was lifted; it is routine now." \
    "the body does not record the lifted hold"
  assert_not_contains "$(tasks "$home" show noticed-held-once --full)" "held: yes" "a routine recurrence kept its old captain hold"
  assert_equals fleet "$(tasks "$home" owner noticed-held-once)" "a routine recurrence is not the fleet's"
  # A dated hold whose date has passed reads unheld but still carries its kind.
  noticed "$home" file noticed held-dated --title "Held dated" --why "first" --from t1 --call machinery >/dev/null
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" hold noticed-held-dated --reason "later" --until 2026-01-01 >/dev/null \
    || fail "could not date the hold"
  noticed "$home" close noticed-held-dated --evidence "settled" >/dev/null
  out=$(noticed "$home" file noticed held-dated --title "Held dated" --why "back" --from t2) \
    || fail "a past-dated held item back as routine could not be reopened: $out"
  assert_equals fleet "$(tasks "$home" owner noticed-held-dated)" "a past-dated routine recurrence is not the fleet's"
  pass "a noticed item is routine by default, --routine still files it so, and only --call holds it for him"
}

# Rule 3 of 2026-11-11: a call held 14 days with no date shows once in the
# Monday triage's "Waiting 2+ weeks", from the snapshot's aged bucket.
test_waiting_lists_each_aged_call_once() {
  local home out
  home=$(make_home waiting)
  cat > "$home/data/backlog.md" <<'EOF2'
## In flight

## Queued
- [ ] old-call - Pick the mat colour (repo: business) (kind: captain) (since 2026-01-01) (hold: which colour) (hold-kind: captain)
  Captain hold set: 2026-01-02T00:00:00Z

  Owner: arjun
- [ ] dated-call - Renew the lease (repo: business) (kind: captain) (since 2026-01-01) (hold: later) (hold-kind: captain) (hold-until: 2099-01-01)
  Captain hold set: 2026-01-02T00:00:00Z

  Owner: arjun
- [ ] new-call - Fresh call (repo: business) (kind: captain) (since 2099-01-01) (hold: today) (hold-kind: captain)
  Captain hold set: 2099-01-01T00:00:00Z

  Owner: arjun

## Done
EOF2
  out=$(noticed "$home" waiting) || fail "waiting failed: $out"
  assert_contains "$out" "old-call	" "an aged call is not listed as waiting"
  assert_contains "$out" "	Pick the mat colour" "a waiting call lost its title"
  assert_not_contains "$out" "dated-call" "a dated call was listed as waiting"
  assert_not_contains "$out" "new-call" "a fresh call was listed as waiting"
  assert_equals "shown: old-call" "$(noticed "$home" waiting --shown old-call)" "waiting --shown did not mark the call"
  assert_equals "" "$(noticed "$home" waiting)" "a call shown once was listed again"
  pass "waiting lists each call held 14 days with no date once, from the aged bucket"
}

test_the_drain_shows_only_urgent_items() {
  local home drain
  home=$(make_home drain)
  drain=$(run_drain "$home") || fail "the drain failed with nothing filed"
  assert_not_contains "$drain" "NOTICED" "the drain printed an empty NOTICED section"
  noticed "$home" file noticed canary-red --title "Canary red" --why "packet" --from t1 --call ruling >/dev/null
  noticed "$home" file idea bundle-slow --title "Bundle slow movers" --why "frees cash" --from t1 >/dev/null
  # A row an earlier version listed for the next reply waits for the triage too.
  tasks "$home" add noticed-old "Old item" --kind noticed >/dev/null || fail "could not add the old row"
  printf 'noticed-old\tnoticed\tOld item\n' >> "$home/state/noticed/unseen.tsv"
  drain=$(run_drain "$home") || fail "the drain failed with unseen items"
  assert_not_contains "$drain" "NOTICED" "the drain showed an item that waits for the Monday triage"
  assert_equals 2 "$(noticed "$home" unseen | wc -l | tr -d ' ')" "the waiting items left the unseen list"
  noticed "$home" file noticed refunds-failing --title "Refunds failing" --why "customers unpaid" \
    --from t2 --now >/dev/null
  drain=$(run_drain "$home") || fail "the drain failed with an urgent item"
  assert_contains "$drain" "NOTICED (urgent or doing harm, not yet told to the captain):" "the section is missing"
  assert_contains "$drain" "noticed-refunds-failing: Refunds failing" "the urgent item is missing from the section"
  assert_not_contains "$drain" "canary-red" "a waiting item was shown beside the urgent one"
  assert_not_contains "$drain" "bundle-slow" "an idea was shown beside the urgent one"
  assert_contains "$drain" "leading your final captain-facing message" "the section does not say to lead his reply with it"
  assert_contains "$drain" "bin/fm-noticed.sh shown <id>" "the section does not say how to mark it shown"
  noticed "$home" shown noticed-refunds-failing >/dev/null
  drain=$(run_drain "$home") || fail "the drain failed after marking"
  assert_not_contains "$drain" "NOTICED" "a shown item was presented again"
  pass "the wake drain shows only an urgent item, until it is marked shown, with no worker status on file"
}

test_now_marks_an_item_urgent() {
  local home out
  home=$(make_home now)
  out=$(noticed "$home" file noticed refunds-failing --title "Refunds failing" --why "customers unpaid" \
    --from t1 --now) || fail "file refused --now: $out"
  assert_equals "filed: noticed-refunds-failing" "$out" "a --now item was not filed"
  assert_contains "$(tasks "$home" show noticed-refunds-failing)" "held: no" "a --now item with no --call was held"
  assert_equals "noticed-refunds-failing	now	Refunds failing" "$(noticed "$home" unseen)" \
    "a --now item is not on the unseen list as now"
  noticed "$home" file noticed refunds-failing --title "Refunds failing" --why "still" --from t2 >/dev/null
  assert_equals "noticed-refunds-failing	now	Refunds failing" "$(noticed "$home" unseen)" \
    "a later sighting without --now demoted the urgent item"

  noticed "$home" file noticed canary-red --title "Canary red" --why "packet" --from t1 >/dev/null
  out=$(noticed "$home" file noticed canary-red --title "Canary red" --why "orders lost" --from t2 --now)
  assert_equals "matched: noticed-canary-red" "$out" "an urgent duplicate was not matched"
  assert_contains "$(noticed "$home" unseen)" "noticed-canary-red	now	Canary red" \
    "an urgent duplicate did not make the open item urgent"
  assert_equals 2 "$(noticed "$home" unseen | wc -l | tr -d ' ')" "making an item urgent listed it twice"

  noticed "$home" shown noticed-canary-red >/dev/null
  tasks "$home" "done" noticed-canary-red >/dev/null || fail "could not close the fixture"
  out=$(noticed "$home" file noticed canary-red --title "Canary red" --why "again" --from t3 --now)
  assert_equals "reopened: noticed-canary-red" "$out" "an urgent recurrence was not reopened"
  assert_contains "$(noticed "$home" unseen)" "noticed-canary-red	now	Canary red" \
    "an urgent recurrence is not listed as now"

  out=$(noticed "$home" file noticed chargebacks --title "Chargebacks rising" --why "account health" \
    --from t1 --now --call ask-first) || fail "file refused --now with --call: $out"
  assert_contains "$(tasks "$home" show noticed-chargebacks)" "held: yes" "a --now --call item is not held"
  assert_contains "$(noticed "$home" unseen)" "noticed-chargebacks	now	Chargebacks rising" \
    "a held urgent item is not listed as now"

  noticed "$home" file idea faster --title a --why b --from t1 --now >/dev/null 2>&1 \
    && fail "an idea was filed as urgent"
  assert_equals "" "$(noticed "$home" unseen | grep idea- || true)" "a refused urgent idea was listed"
  pass "--now files, matches or reopens a noticed item as urgent, held or not, keeps it urgent, and refuses an idea"
}

test_unseen_drops_closed_rows_and_keeps_titles_whole() {
  local home long out list
  home=$(make_home tidy)
  long="Packing slips print the warehouse copy twice when a batch spans two printers and one of them is asleep"
  noticed "$home" file noticed slips-twice --title "$long" --why "paper" --from t1 >/dev/null
  noticed "$home" close noticed-slips-twice --evidence "one copy per batch" --fixed \
    --pr https://github.com/o/r/pull/5 >/dev/null || fail "close --fixed refused a long title"
  assert_equals "noticed-slips-twice	fixed	$long - one copy per batch (https://github.com/o/r/pull/5)" \
    "$(noticed "$home" unseen)" "a long title was not stored whole on one line"

  noticed "$home" file noticed open-one --title "Still open" --why "w" --from t1 --call ruling >/dev/null
  noticed "$home" file noticed shut-elsewhere --title "Shut by a teardown" --why "w" --from t1 --call ruling >/dev/null
  noticed "$home" file noticed urgent-shut --title "Urgent and shut" --why "w" --from t1 --now >/dev/null
  tasks "$home" "done" noticed-shut-elsewhere >/dev/null || fail "could not close a row outside fm-noticed.sh"
  tasks "$home" "done" noticed-urgent-shut >/dev/null || fail "could not close the urgent row"
  # Rows an older close split over two lines after tasks-axi's 80-character
  # cut, an entry whose row was archived, and a split half whose entry is gone.
  cut="Word word word word word word word word word word word word word word word word "
  printf '%s\n' "noticed-old-fix	fixed	$cut" \
    "... (truncated, 98 chars total - use --full to see complete text) - fixed at its cause (https://github.com/o/r/pull/2)" \
    "noticed-archived	noticed	Archived long ago" \
    "noticed-shown-fix	fixed	$cut" \
    "... (truncated, 90 chars total - use --full to see complete text) - shown already (https://github.com/o/r/pull/6)" \
    "noticed-orphan-before	dropped	A short title" \
    "... (truncated, 91 chars total - use --full to see complete text) - an orphaned half" >> "$home/state/noticed/unseen.tsv"
  assert_equals "shown: noticed-shown-fix" "$(noticed "$home" shown noticed-shown-fix)" "shown did not mark a split entry"
  assert_not_contains "$(cat "$home/state/noticed/unseen.tsv")" "shown already" "shown left a split entry's second half behind"
  list=$(noticed "$home" unseen) || fail "unseen failed"
  assert_contains "$list" "noticed-open-one	noticed	Still open" "an open noticed row left the list"
  assert_not_contains "$list" "noticed-shut-elsewhere" "a noticed row closed by another path stayed listed"
  assert_not_contains "$list" "noticed-archived" "a noticed row no longer in the backlog stayed listed"
  assert_contains "$list" "noticed-urgent-shut	now	Urgent and shut" "a now row he was not told about left the list"
  assert_contains "$list" "noticed-old-fix	fixed	${cut% }... - fixed at its cause (https://github.com/o/r/pull/2)" \
    "a split fixed title was not rejoined"
  assert_contains "$list" "noticed-orphan-before	dropped	A short title" "an entry before an unpaired half changed"
  assert_contains "$list" "an orphaned half" "a half that matches no cut entry was joined or lost"
  assert_equals "$list" "$(cat "$home/state/noticed/unseen.tsv")" "the tidy was not written back for the drain"
  assert_equals "$(printf '%s\n' "$list" | grep -c 'truncated, ')" 1 "a paired truncation pointer stayed in the list"

  printf 'noticed-gone\tnoticed\tGone\n' >> "$home/state/noticed/unseen.tsv"
  fm_fakebin "$home/broken" >/dev/null
  printf '#!/usr/bin/env bash\necho "backend down" >&2\nexit 1\n' > "$home/broken/fakebin/tasks-axi"
  chmod +x "$home/broken/fakebin/tasks-axi"
  out=$(PATH="$home/broken/fakebin:$PATH" noticed "$home" unseen 2>/dev/null)
  assert_contains "$out" "noticed-gone	noticed	Gone" "a failed backlog read pruned an entry"
  # A listing that exits 0 but holds fewer rows than its count line says.
  cat > "$home/broken/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'count: 2\ntasks[2]{id,state,kind,repo,title}:\n  noticed-open-one,queued,noticed,"-",Still open\n'
SH
  out=$(PATH="$home/broken/fakebin:$PATH" noticed "$home" unseen 2>/dev/null)
  assert_contains "$out" "noticed-gone	noticed	Gone" "a partial backlog listing pruned an entry"
  # A listing whose count agrees but whose second row is not a row.
  cat > "$home/broken/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'count: 2\ntasks[2]{id,state,kind,repo,title}:\n  noticed-open-one,queued,noticed,"-",Still open\n  garbage\n'
SH
  out=$(PATH="$home/broken/fakebin:$PATH" noticed "$home" unseen 2>/dev/null)
  assert_contains "$out" "noticed-gone	noticed	Gone" "a listing with a malformed row pruned an entry"
  # A zero count that contradicts its table, and a row cut short.
  cat > "$home/broken/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'count: 0\ntasks[1]{id,state,kind,repo,title}:\n  noticed-open-one,queued,noticed,"-",Still open\n'
SH
  out=$(PATH="$home/broken/fakebin:$PATH" noticed "$home" unseen 2>/dev/null)
  assert_contains "$out" "noticed-gone	noticed	Gone" "a zero count with a table pruned an entry"
  cat > "$home/broken/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'count: 1\ntasks[1]{id,state,kind,repo,title}:\n  noticed-gone,done\n'
SH
  out=$(PATH="$home/broken/fakebin:$PATH" noticed "$home" unseen 2>/dev/null)
  assert_contains "$out" "noticed-gone	noticed	Gone" "a row cut short pruned an entry"
  pass "unseen drops noticed rows closed by any path, keeps now, fixed and dropped rows, rejoins split titles, and prunes nothing on a failed read"
}

test_a_secondmate_hands_ideas_and_calls_to_the_main_home() {
  local home parent channel out rc span needs
  home=$(make_home mate)
  parent="$TMP_ROOT/mate-parent"
  mkdir -p "$parent/state"
  channel="$parent/state/sample-mate.status"
  printf 'sample-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"

  out=$(noticed "$home" file idea faster-sweep --title "Sweep faster" --why "it saves a wake" \
    --from sm-task --repo firstmate --evidence "sweep log") || fail "a mate refused a valid idea: $out"
  [ "$out" = "handed-up: idea-faster-sweep" ] || fail "a mate idea did not report handed-up: $out"
  ! tasks "$home" show idea-faster-sweep >/dev/null 2>&1 || fail "a mate kept a local row for an idea it handed up"
  grep -q '^needs-decision \[key=noticed-queue-idea-faster-sweep\] \[at=[0-9]*\]: noticed-queue idea idea-faster-sweep: Sweep faster - why: it saves a wake - from: sm-task - repo: firstmate - evidence: sweep log$' \
    "$channel" || fail "the parent channel line does not carry every field: $(cat "$channel")"
  # The real classifier: the line wakes the parent as a decision, and a
  # resolved line for its key, which bin/fm-send.sh --resolve-key writes, closes it.
  span=$(bash -c '. "$1"; status_span_first_actionable_record "$2" 0 rec nd; rc=$?; printf "%s %s" "$rc" "$nd"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$channel")
  [ "$span" = "0 1" ] || fail "the handed-up line did not read as a new parent decision: $span"
  printf 'resolved [key=noticed-queue-idea-faster-sweep] [at=1]: answered: filed in the main home\n' >> "$channel"
  ! bash -c '. "$1"; status_has_open_needs_decision "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$channel" \
    || fail "a resolved line did not close the handed-up decision"
  # Seen again after the main home answered it: never re-asked.
  out=$(noticed "$home" file idea faster-sweep --title "Sweep faster" --why "seen again" --from sm-task) \
    || fail "a mate refused a repeat idea: $out"
  [ "$out" = "skipped: idea-faster-sweep (handed to the main home or answered earlier)" ] || fail "a repeat idea was not skipped: $out"
  [ "$(grep -c '^needs-decision \[key=noticed-queue-idea-faster-sweep\]' "$channel")" = 1 ] \
    || fail "an answered idea was asked again: $(cat "$channel")"

  out=$(noticed "$home" file noticed slow-canary --title "Canary slow" --why "it may time out" \
    --from sm-task --call ruling) || fail "a mate refused a valid --call item: $out"
  [ "$out" = "handed-up: noticed-slow-canary" ] || fail "a mate --call item did not report handed-up: $out"
  grep -q '^needs-decision \[key=noticed-queue-noticed-slow-canary\] .*noticed-queue noticed noticed-slow-canary (call: ruling): Canary slow - why: it may time out - from: sm-task$' \
    "$channel" || fail "the --call item did not reach the parent channel with its call kind: $(cat "$channel")"
  ! tasks "$home" show noticed-slow-canary >/dev/null 2>&1 || fail "a mate kept a local row for a --call item it handed up"

  # Over-long evidence is cut to fit the channel; a title too long to fit is
  # refused before anything is sent.
  out=$(noticed "$home" file idea long-proof --title "Long proof" --why "big log" --from sm-task \
    --evidence "$(printf 'x%.0s' $(seq 1 1500))") || fail "a mate refused an idea with long evidence: $out"
  grep -q '^needs-decision \[key=noticed-queue-idea-long-proof\] .*: noticed-queue idea idea-long-proof: Long proof - why: big log - from: sm-task - evidence: xxx' \
    "$channel" || fail "an idea with long evidence lost its fields on the parent channel"
  set +e
  out=$(noticed "$home" file idea long-title --title "$(printf 't%.0s' $(seq 1 1300))" --why "w" --from sm-task 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an idea too long to hand up must be refused"
  ! grep -q 'idea-long-title' "$channel" || fail "an idea too long to hand up reached the parent channel"
  # The cap is in bytes: 700 two-byte characters are 1400 bytes.
  set +e
  out=$(LC_ALL=C.UTF-8 noticed "$home" file idea wide-title --title "$(printf 'é%.0s' $(seq 1 700))" --why "w" --from sm-task 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "a multi-byte title past the byte cap must be refused"
  # A main home has no channel cap: the same long title files locally.
  out=$(noticed "$(make_home long-main)" file idea long-title --title "$(printf 't%.0s' $(seq 1 1300))" --why "w" --from firstmate) \
    || fail "a main home refused a long idea: $out"
  [ "$out" = "filed: idea-long-title" ] || fail "a main home did not file its long idea locally: $out"

  out=$(noticed "$home" file noticed flaky-test --title "Flaky test" --why "CI reruns" --from sm-task) \
    || fail "a mate refused a routine item: $out"
  [ "$out" = "filed: noticed-flaky-test" ] || fail "a mate did not file its routine item locally: $out"
  ! grep -q 'flaky-test' "$channel" || fail "a routine item went to the parent channel"
  # The same item seen again as a call goes up, and its routine row here closes.
  out=$(noticed "$home" file noticed flaky-test --title "Flaky test" --why "it blocks merges" --from sm-task --call ruling) \
    || fail "a mate refused a --call for its routine item: $out"
  [ "$out" = "handed-up: noticed-flaky-test" ] || fail "a routine item seen as a call was not handed up: $out"
  assert_contains "$(tasks "$home" show noticed-flaky-test)" "state: done" \
    "the routine row of a handed-up call stayed open for the mate to fix"

  rm "$home/.fm-secondmate-parent"
  set +e
  out=$(noticed "$home" file idea lost-idea --title "Lost" --why "no channel" --from sm-task 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a mate with no parent binding must not report an idea handed up"
  assert_contains "$out" "could not hand idea-lost-idea to the main home" "the failure did not name the item"
  ! tasks "$home" show idea-lost-idea >/dev/null 2>&1 || fail "a failed hand-up filed the idea locally after all"
  pass "a secondmate hands ideas and --call items to the main home on its parent channel and files routine items locally"
}

test_noticed_is_a_captain_hold_that_never_dispatches
test_a_secondmate_hands_ideas_and_calls_to_the_main_home
test_a_duplicate_attaches_evidence
test_closed_items_come_back_or_stay_answered
test_refusals
test_collect_reads_the_report_then_notes
test_close_settles_an_item_and_list_keeps_answered_ones
test_now_marks_an_item_urgent
test_a_fix_on_its_own_waits_for_the_triage
test_a_routine_item_is_never_held_for_him
test_waiting_lists_each_aged_call_once
test_the_drain_shows_only_urgent_items
test_unseen_drops_closed_rows_and_keeps_titles_whole
