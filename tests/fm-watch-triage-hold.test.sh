#!/usr/bin/env bash
# tests/fm-watch-triage-hold.test.sh - work the captain or a delivered
# worker already accounts for: captain-held churn and open decisions bounded
# instead of re-alarming, a done worker with a recorded PR noticed once, and
# the away-posture record silencing captain-held rechecks.
# Shared fixtures and the family map live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# --- work the captain is already holding: pane churn must not re-alarm -------
# The other record of a legitimate wait. The declared-wait bound above reads the
# status LINE, and a delivered task's line stays `done: PR ...` while the wait
# itself lives in the BACKLOG, written there by bin/fm-captain-hold.sh. No line
# predicate can see that record, so both stale alarms - the captain-relevant one
# and the inconclusive one - re-fired on every new pane hash for as long as the
# captain was deciding, which is the 2026-09 loop observed on delivered work
# awaiting their merge word.
# Pinned here, in both directions: while the call stands the first sight still
# alarms, further sights of the SAME call and status-log state are absorbed, and
# a new pane hash after the window's end alarms once more; and the identical
# fixture WITHOUT the hold keeps alarming on every hash, because a bound that
# swallowed an unheld delivery or blocker would be worse than the churn it removes.
#
# The backlog is real rather than a fixture file: bin/fm-captain-hold.sh is the
# only writer of a hold and tasks-axi the only reader, so a hand-written row
# would pin this test's idea of a hold instead of the one the watcher consults.
#
# Cost: every case below drives churn through ONE watcher process rather than
# relaunching per pane change. Watcher startup dominates a round here, and an
# absorbing watcher stays in its poll loop across churn in production anyway, so
# the cheaper shape is also the more faithful one.

# The window key every hold fixture uses, derived the way fm-watch.sh derives it.
hold_key() {
  printf '%s' test:fm-held-merge | tr ':/.' '___'
}

make_hold_home() {  # <name> <status-line> <hold|nohold>
  local name=$1 line=$2 hold=$3 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml" || return 1
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add held-merge 'delivered work' --file data/backlog.md) >/dev/null 2>&1 \
    || return 1
  if [ "$hold" = hold ]; then
    run_hold "$dir" hold held-merge --reason 'awaiting the captain on the merge' || return 1
  fi
  printf 'window=test:fm-held-merge\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/held-merge.meta"
  printf '%s\n' "$line" > "$state/held-merge.status"
  printf '%s' "$(seen_sig "$state/held-merge.status")" > "$state/.seen-held-merge_status"
  printf '%s\n' "$dir"
}

# Launch one watcher against a hold fixture, armed the way parked_watch_round
# arms one, plus the home the backlog read resolves against. The crew reads
# stopped: a delivered worker's agent has exited, and that is the population
# whose alarm the call must bound. The pid lands in HOLD_WATCH_PID rather than on
# stdout: a command substitution would background the watcher inside a subshell,
# leaving the caller unable to wait on or reap its own watcher.
HOLD_WATCH_PID=
hold_watch_launch() {  # <dir> <out> <capture>
  local dir=$1 out=$2 capture=$3
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-held-merge \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_HOLD_PAUSE_RESURFACE_SECS:-999}" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  HOLD_WATCH_PID=$!
}

# One sighting that must surface and exit the cycle.
hold_watch_surface() {  # <dir> <out> <capture> <pane-text>
  local dir=$1 out=$2 capture=$3 text=$4
  printf '%s\n' "$text" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100 || { reap "$HOLD_WATCH_PID"; return 1; }
  return 0
}

# <count> successive pane changes driven through ONE watcher, each given three
# poll cycles: one to see the new hash, one to count it stable and classify, one
# to prove the classification held. The watcher must stay in the loop throughout.
hold_watch_churn() {  # <dir> <out> <capture> <label> <count>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$HOLD_WATCH_PID" 300 \
        || { reap "$HOLD_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$HOLD_WATCH_PID"
  return 0
}

hold_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-held-merge" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# Both status lines a held task really carries: the delivery that routes through
# the captain-relevant stale branch, and a worker line that routes through the
# inconclusive one. The hold is invisible to the status line in both, so both
# branches had the same blindness and both are covered.
test_open_captain_call_bounds_stale_churn() {
  local spec name line dir state out capture throttle wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (captain-hold stale bound)"; return 0; }
  for spec in \
    'held-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'held-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" hold) \
      || fail "[$name] could not build a captain-held backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    throttle="$state/.paused-resurfaced-$(hold_key)"

    # First sight still alarms: the call bounds repetition, never the first look.
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
      || fail "[$name] first sight of held work did not surface"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "[$name] first sight produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"

    # The pane churns while the SAME call stands. Every one of these alarmed.
    hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 2 \
      || fail "[$name] watcher exited during pane churn instead of supervising through it"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 0 ] \
      || fail "[$name] pane churn re-alarmed held work $wakes time(s) inside the re-surface window"

    # After the window ends, the next new pane hash re-surfaces held work exactly
    # once, so a forgotten call on a churning pane cannot hide behind the bound.
    [ -e "$throttle" ] || fail "[$name] the absorbed churn recorded no re-surface cadence to elapse"
    set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 9s' \
      || fail "[$name] held work did not re-surface once its re-surface window elapsed"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] \
      || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
  done
  pass "work under an open captain call surfaces once, absorbs pane churn, then re-surfaces when the window elapses"
}

# The other half of the same bound, and the one that decides whether widening the
# wait was safe: the identical fixtures with NO hold must keep alarming on every
# new hash, on both branches. A blocker is not among them: its open decision is a
# record of its own (test_open_decision_bounds_stale_churn).
test_stale_churn_without_a_captain_call_still_alarms() {
  local spec name line dir state out capture round wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (unheld stale alarm)"; return 0; }
  for spec in \
    'unheld-delivery|done: PR https://example.invalid/pull/1 checks green' \
    'unheld-worker-line|working: still tidying the branch'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" nohold) \
      || fail "[$name] could not build an unheld backlog fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    round=1
    while [ "$round" -le 2 ]; do
      hold_watch_surface "$dir" "$out" "$capture" "idle, elapsed ${round}s" \
        || fail "[$name] an unheld stale window stopped alarming on round $round"
      wakes=$(hold_stale_wakes "$state")
      [ "$wakes" -eq 1 ] \
        || fail "[$name] round $round produced $wakes wakes instead of one"
      ack_stopped_cycle "$state" || fail "[$name] could not acknowledge round $round"
      round=$((round + 1))
    done
  done
  pass "a stale window with no open captain call or open decision keeps alarming on every new hash"
}

# A worker waiting on its own open decision - a needs-decision question, a
# blocker, or either one still open beneath a later working: line - already
# reaches firstmate through the signal that carried it and on every drain's OPEN
# DECISIONS until a resolved line closes it. Its idle pane's churn must not
# re-alarm it inside the re-surface window, while the first sight and the
# window's end still surface, and resolving the decision restores the alarm.
test_open_decision_bounds_stale_churn() {
  local spec name line dir state out capture throttle wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (open-decision stale bound)"; return 0; }
  for spec in \
    'open-question|needs-decision [key=reattach]: waiting on the captain to re-attach the browser' \
    'open-blocker|blocked: cannot reach the release host' \
    $'open-beneath-working|needs-decision [key=reattach]: waiting on the captain\nworking: tidying while the question stands'
  do
    name=${spec%%|*}; line=${spec#*|}
    dir=$(make_hold_home "$name" "$line" nohold) \
      || fail "[$name] could not build an open-decision fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    throttle="$state/.paused-resurfaced-$(hold_key)"

    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
      || fail "[$name] first sight of a worker waiting on its open decision did not surface"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "[$name] first sight produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"

    hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 2 \
      || fail "[$name] watcher exited during pane churn instead of supervising through it"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 0 ] \
      || fail "[$name] pane churn re-alarmed an open decision $wakes time(s) inside the re-surface window"

    [ -e "$throttle" ] || fail "[$name] the absorbed churn recorded no re-surface cadence to elapse"
    set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
    hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 9s' \
      || fail "[$name] an open decision did not re-surface once its re-surface window elapsed"
    wakes=$(hold_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the elapsed re-surface"
  done

  # Closing the decision ends the bound: the next new hash is a fresh first sight.
  printf 'resolved [key=reattach]: the captain re-attached the browser\nworking: back on the theme\n' \
    >> "$state/held-merge.status"
  printf '%s' "$(seen_sig "$state/held-merge.status")" > "$state/.seen-held-merge_status"
  hold_watch_surface "$dir" "$out" "$capture" 'idle, after resolve' \
    || fail "a resolved decision kept absorbing the stale alarm"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] || fail "after resolve, a new hash produced $wakes wakes instead of one"
  pass "a worker waiting on its open decision surfaces once, absorbs pane churn, re-surfaces when the window elapses, and alarms again once resolved"
}

# The cadence marker may never outlive the wake it claims to record. Recording it
# before publishing the durable wake turned a delayed alarm into a lost one: the
# append fails, the watcher exits with nothing queued, and the next sighting
# reads that fresh marker and absorbs the retry. An unwritable queue is the real
# failure, so it is the one this drives.
test_failed_wake_append_does_not_arm_the_captain_hold_throttle() {
  local dir state out capture wakes rc
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (failed wake append)"; return 0; }
  dir=$(make_hold_home append-failure 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # A directory where the queue file belongs: every append fails, whatever the
  # caller does, so the watcher cannot publish the wake it just decided to send.
  # Its exit code is read directly here because a refusing watcher exits NON-zero,
  # which is the correct outcome and not the "surfaced" one hold_watch_surface means.
  rm -f "$state/.wake-queue"
  mkdir -p "$state/.wake-queue"
  printf 'idle, elapsed 1s\n' > "$capture"
  hold_watch_launch "$dir" "$out" "$capture"
  wait_for_exit "$HOLD_WATCH_PID" 100
  rc=$?
  rmdir "$state/.wake-queue"
  [ "$rc" -ne 124 ] || fail "the watcher did not exit when its durable queue could not be written"
  [ "$rc" -ne 0 ] || fail "the watcher reported success despite an unwritable durable queue"
  [ -e "$state/.paused-resurfaced-$(hold_key)" ] \
    && fail "a wake that never reached the durable queue still armed the re-surface throttle"

  # The retry must alarm: nothing was ever delivered, so nothing may be absorbed.
  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 2s' \
    || fail "the retry after a failed wake append was absorbed instead of alarming"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the retry after a failed wake append produced $wakes wakes instead of one"
  pass "a wake that never reached the durable queue arms no re-surface throttle"
}

# The task id is not the captain call. A task can be answered with `--release`
# and held again as a genuinely different call with NO status append, and binding
# the throttle to the status-log signature alone let the second call inherit the
# first one's silence and absorbed its first sight. That is the one alarm this
# bound must never swallow: a delivery announced twice is noise, but a decision
# waiting on the captain that is never surfaced is invisible.
# Measured at base c499f84 this fixture alarms on every sighting, so the
# suppression was introduced by the bound itself rather than pre-existing.
test_reheld_captain_call_starts_its_own_resurface_window() {
  local dir state out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (re-held captain call)"; return 0; }
  dir=$(make_hold_home reheld-call 'done: PR https://example.invalid/pull/1 checks green' hold) \
    || fail "could not build a captain-held backlog fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 1s' \
    || fail "first sight of the first captain call did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first call's surface"
  hold_watch_churn "$dir" "$out" "$capture" 'idle, tick' 1 \
    || fail "the first call's churn was not absorbed"
  [ "$(hold_stale_wakes "$state")" -eq 0 ] \
    || fail "the first call's churn re-alarmed inside its own window"

  # Answer and release, then re-hold: a second, distinct captain call on the same
  # task id, with no status append, so the status signature cannot tell them apart.
  printf 'go ahead\n' > "$dir/decision.txt"
  run_hold "$dir" answer held-merge --decision-file "$dir/decision.txt" --release \
    || fail "could not record the captain's answer"
  run_hold "$dir" hold held-merge --reason 'awaiting the captain a second time' \
    || fail "could not re-hold the task as a second captain call"

  hold_watch_surface "$dir" "$out" "$capture" 'idle, elapsed 3s' \
    || fail "the second captain call inherited the first call's silence"
  wakes=$(hold_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the second captain call produced $wakes first wakes instead of one"
  pass "a released-then-re-held task is a distinct captain call whose first sight still alarms"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\nThe release window opens tomorrow.\n\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "awaiting the captain" "$out" >/dev/null && fail "paused secondmate recheck named the captain instead of its external dependency"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

# A captain hold is the other declared wait, but unlike paused: it has no
# current-state mapping, so a held mate reports `unknown` rather than `paused`.
# The bounded re-surface must still reach it, or a mate's hold rots invisibly:
# nothing else re-reads a quiet mate's endpoint.
test_secondmate_captain_held_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-held-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a captain-held secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "captain-held secondmate did not emit a stale recheck"
  grep -F "awaiting the captain" "$out" >/dev/null || fail "captain-held secondmate recheck did not name the captain as the blocker: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "captain-held secondmate recheck claimed an external wait"
  grep -F "possible wedge" "$out" >/dev/null && fail "captain-held secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional entered-pause watcher stop"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional authoritative-working stop"

  # Past the threshold the timer asks whether the pane can explain its own quiet
  # before it escalates, and the worker's declaration is that explanation: the
  # override decides which BOOKKEEPING owns the pane, not whether the wait the
  # worker declared still stands. This is the idle-pane counterpart of the busy
  # pane's declared-wait exception above, which the two paths used to disagree on.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a still-declared wait wedge-escalated past the threshold under a working verdict: $(cat "$out")"
  fi
  reap "$pid"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "a still-declared wait was reported as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "a still-declared wait counted $(cat "$state/.wedge-escalations-$key") wedge escalation(s)"

  # Lifting the declaration restores the unchanged escalation, which is what
  # keeps the deferral above from being indistinguishable from no detection.
  printf 'working: resumed after the release landed\n' >> "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "authoritative working state did not wedge-escalate past the threshold once the declaration was lifted"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer, is rechecked rather than wedge-escalated while the declaration stands, and escalates once it is lifted"
}

# --- a delivered worker, done with a recorded PR: one notice, then bounded -----
# The 2026-09-10 loop: a worker appends `done: PR <url>`, sits at its prompt
# waiting for the merge word, and its idle prompt still ticks its render, so every
# few minutes a new pane hash re-alarmed a delivery firstmate already had in hand
# (fm-pr-check had recorded pr=), a dozen empty handling turns a day. The bound is
# keyed on CURRENT state reading done (the fake fm-crew-state verdict, never the
# status line alone) plus the pr= record, and it is bounded exactly like the
# declared-pause and captain-call cadences.
# Pinned in both directions on one fixture family: first sight alarms, churn
# inside the window is absorbed, the elapsed window re-surfaces once; and the
# exemption ends when the state stops reading done or the status log moves,
# while a done worker with NO pr= record keeps alarming on every new hash.

delivered_key() {
  printf '%s' test:fm-delivered | tr ':/.' '___'
}

# One watcher against a delivered fixture. The crew-state verdict is the
# parameter, because the whole bound turns on what the AUTHORITATIVE reader says.
DELIVERED_WATCH_PID=
delivered_watch_launch() {  # <dir> <out> <capture> <crew-state-line>
  local dir=$1 out=$2 capture=$3 verdict=$4
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-delivered \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_FAKE_CREW_STATE="$verdict" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" 2>&1 &
  DELIVERED_WATCH_PID=$!
}

delivered_watch_surface() {  # <dir> <out> <capture> <pane-text> <crew-state-line>
  local dir=$1 out=$2 capture=$3 text=$4 verdict=$5
  printf '%s\n' "$text" > "$capture"
  delivered_watch_launch "$dir" "$out" "$capture" "$verdict"
  wait_for_exit "$DELIVERED_WATCH_PID" 100 || { reap "$DELIVERED_WATCH_PID"; return 1; }
  return 0
}

# <count> successive pane changes through ONE watcher, three poll cycles each,
# the watcher staying in its loop throughout (the shape hold_watch_churn uses).
delivered_watch_churn() {  # <dir> <out> <capture> <label> <count> <crew-state-line>
  local dir=$1 out=$2 capture=$3 label=$4 count=$5 verdict=$6 i=1 c
  local state="$dir/state"
  printf '%s 0\n' "$label" > "$capture"
  delivered_watch_launch "$dir" "$out" "$capture" "$verdict"
  while [ "$i" -le "$count" ]; do
    printf '%s %s\n' "$label" "$i" > "$capture"
    c=0
    while [ "$c" -lt 3 ]; do
      wait_poll_cycle "$state" "$DELIVERED_WATCH_PID" 300 \
        || { reap "$DELIVERED_WATCH_PID"; return 1; }
      c=$((c + 1))
    done
    i=$((i + 1))
  done
  reap "$DELIVERED_WATCH_PID"
  return 0
}

delivered_stale_wakes() {  # <state>
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-delivered" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

make_delivered_home() {  # <name> <pr-record|nopr>
  local name=$1 pr=$2 dir state
  dir=$(make_case "$name"); state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  printf 'window=test:fm-delivered\nkind=ship\nharness=grok\nbackend=tmux\n' \
    > "$state/delivered.meta"
  [ "$pr" = nopr ] || printf 'pr=%s\n' "$pr" >> "$state/delivered.meta"
  printf 'done: PR https://example.invalid/pull/7\n' > "$state/delivered.status"
  printf '%s' "$(seen_sig "$state/delivered.status")" > "$state/.seen-delivered_status"
  printf '%s\n' "$dir"
}

DELIVERED_DONE='state: done · source: status-log · PR https://example.invalid/pull/7'

test_done_worker_with_recorded_pr_surfaces_once_then_absorbs_churn() {
  local dir state out capture throttle wakes
  dir=$(make_delivered_home delivered-bound 'https://example.invalid/pull/7') \
    || fail "could not build a delivered fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
  throttle="$state/.paused-resurfaced-$(delivered_key)"

  # First sight still alarms: the bound covers repetition, never the first look.
  delivered_watch_surface "$dir" "$out" "$capture" 'idle prompt, elapsed 1s' "$DELIVERED_DONE" \
    || fail "first sight of a delivered worker did not surface"
  wakes=$(delivered_stale_wakes "$state")
  [ "$wakes" -eq 1 ] || fail "first sight produced $wakes wakes instead of one"
  [ -e "$throttle" ] || fail "the first alarm recorded no re-surface cadence for the delivery"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first surface"

  # The idle prompt keeps ticking while the same delivery stands. Every one of
  # these alarmed before.
  delivered_watch_churn "$dir" "$out" "$capture" 'idle prompt, tick' 2 "$DELIVERED_DONE" \
    || fail "watcher exited during idle-prompt churn instead of supervising through it"
  wakes=$(delivered_stale_wakes "$state")
  [ "$wakes" -eq 0 ] \
    || fail "idle-prompt churn re-alarmed a delivered worker $wakes time(s) inside the re-surface window"
  [ ! -e "$state/.stale-since-$(delivered_key)" ] \
    || fail "a delivered-worker absorb started a wedge timer"

  # After the window ends, the next new pane hash re-surfaces the delivery exactly
  # once, so a forgotten PR cannot hide behind the bound.
  set_mtime "$(( $(date +%s) - 5000 ))" "$throttle"
  delivered_watch_surface "$dir" "$out" "$capture" 'idle prompt, elapsed 9s' "$DELIVERED_DONE" \
    || fail "a delivered worker did not re-surface once its window elapsed"
  wakes=$(delivered_stale_wakes "$state")
  [ "$wakes" -eq 1 ] \
    || fail "the elapsed window produced $wakes wakes instead of one"
  pass "a done worker with a recorded PR surfaces once, absorbs its idle-prompt churn, then re-surfaces when the window elapses"
}

# The exemption is keyed on CURRENT state, so it ends the moment the authoritative
# reader stops saying done - the status line still reads `done: PR ...` in every
# case below, and must not be what keeps the bound alive.
test_done_worker_bound_ends_when_state_is_no_longer_done() {
  local dir state out capture wakes verdict spec name
  for spec in \
    'relaunched-unknown|state: unknown · source: none · backend target gone: test:fm-delivered' \
    'exited-stopped|state: stopped · source: pane · bare shell' \
    'failed-later|state: failed · source: run-step · failed'
  do
    name=${spec%%|*}; verdict=${spec#*|}
    dir=$(make_delivered_home "delivered-$name" 'https://example.invalid/pull/7') \
      || fail "[$name] could not build a delivered fixture"
    state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
    delivered_watch_surface "$dir" "$out" "$capture" 'idle prompt, elapsed 1s' "$DELIVERED_DONE" \
      || fail "[$name] first sight of a delivered worker did not surface"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"
    # Same status line, same recorded PR, a new hash - but the state moved.
    delivered_watch_surface "$dir" "$out" "$capture" 'idle prompt, elapsed 2s' "$verdict" \
      || fail "[$name] a delivered worker whose state stopped reading done was still absorbed"
    wakes=$(delivered_stale_wakes "$state")
    [ "$wakes" -eq 1 ] \
      || fail "[$name] the state change produced $wakes wakes instead of one"
  done
  pass "a delivered worker's bound ends as soon as its current state stops reading done, whatever the status line says"
}

# A new status event is a new window: the scope binds the status-log signature,
# so the worker's next line alarms once even while the state still reads done.
test_done_worker_bound_ends_on_a_new_status_event() {
  local dir state out capture wakes
  dir=$(make_delivered_home delivered-new-event 'https://example.invalid/pull/7') \
    || fail "could not build a delivered fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
  delivered_watch_surface "$dir" "$out" "$capture" 'idle prompt, elapsed 1s' "$DELIVERED_DONE" \
    || fail "first sight of a delivered worker did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first surface"
  delivered_watch_churn "$dir" "$out" "$capture" 'idle prompt, tick' 1 "$DELIVERED_DONE" \
    || fail "watcher exited during idle-prompt churn"
  [ "$(delivered_stale_wakes "$state")" -eq 0 ] || fail "churn inside the window alarmed"
  printf 'done: PR https://example.invalid/pull/7 rebased onto main\n' >> "$state/delivered.status"
  printf '%s' "$(seen_sig "$state/delivered.status")" > "$state/.seen-delivered_status"
  delivered_watch_surface "$dir" "$out" "$capture" 'idle prompt, elapsed 3s' "$DELIVERED_DONE" \
    || fail "a new status event on a delivered worker was absorbed under the old window"
  wakes=$(delivered_stale_wakes "$state")
  [ "$wakes" -eq 1 ] || fail "the new status event produced $wakes wakes instead of one"
  pass "a new status event starts its own window for a delivered worker"
}

# The record that makes the bound safe: without pr=, nothing says firstmate has
# taken the delivery in hand, so the identical fixture keeps alarming on every
# new hash exactly as before.
test_done_worker_without_recorded_pr_still_alarms_on_every_hash() {
  local dir state out capture round wakes
  dir=$(make_delivered_home delivered-nopr nopr) \
    || fail "could not build an unrecorded delivered fixture"
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"
  round=1
  while [ "$round" -le 2 ]; do
    delivered_watch_surface "$dir" "$out" "$capture" "idle prompt, elapsed ${round}s" "$DELIVERED_DONE" \
      || fail "a done worker with no recorded PR stopped alarming on round $round"
    wakes=$(delivered_stale_wakes "$state")
    [ "$wakes" -eq 1 ] || fail "round $round produced $wakes wakes instead of one"
    ack_stopped_cycle "$state" || fail "could not acknowledge round $round"
    round=$((round + 1))
  done
  [ ! -e "$state/.paused-resurfaced-$(delivered_key)" ] \
    || fail "a done worker with no recorded PR armed a re-surface throttle"
  pass "a done worker with no recorded PR keeps alarming on every new hash"
}

# The worktree recorded for a secondmate is a provisioned firstmate home, and that
# home runs its OWN supervision inside itself: its watcher beacon, pane hashes and
# heartbeats keep state/ churning whether or not the mate produced anything. Reading
# that as crew progress would quietly relax the kind-agnostic busy-turn backstop from
# the escalation cadence to the hourly recheck for work that produced nothing, so the
# probe must report no evidence and the unchanged schedule must still fire.
test_secondmate_home_supervision_churn_is_not_write_evidence() {
  local dir state fakebin out drain_out capture_file window key sig pid home back
  dir=$(make_case secondmate-home-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-mate"; home="$dir/mate-home"
  mkdir -p "$home/state"
  printf 'sm-mate\n' > "$home/.fm-secondmate-home"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\nworktree=%s\n' "$window" "$home" > "$state/mate.meta"
  record_pi_busy "$state" mate
  # An ordinary crew recording a provisioned mate home is the route that actually
  # reaches the probe: a kind=secondmate window of its own is triaged only under a
  # declared pause, and a declared pause takes the bounded recheck cadence instead of
  # the wedge timer. The home marker alone is what excludes the walk, so the exclusion
  # is what this asserts. A busy pane is bounded by its completed-turn age; no turn
  # ever completed here, so the spawn record itself is aged past the bound that routes
  # it into the wedge timer.
  printf 'working: implementing\n' > "$state/mate.status"
  sig=$(seen_sig "$state/mate.status"); printf '%s' "$sig" > "$state/.seen-mate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  set_mtime "$(( $(date +%s) - 4000 ))" "$state/mate.meta"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # The only thing written since the idle window opened is the mate home's own
  # supervision bookkeeping.
  printf 'beat\n' > "$home/state/.last-watcher-beat"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_BUSY_TURN_MAX_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a mate home's own supervision churn deferred an escalation it must not defer"
  grep -F "stale: $window" "$out" >/dev/null || fail "the mate-home escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the mate-home escalation did not flag a possible wedge"
  [ ! -e "$state/.writing-since-$key" ] || fail "a mate's provisioned home was probed as if it were a code tree"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the mate escalation was not counted"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the mate escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the mate escalation was not queued"
  pass "a secondmate's own home supervision churn is not crew write evidence, so a pane recording that home keeps the unchanged escalation schedule"
}

# A write deferral is a bounded chain, not a permanent one: its .writing-since
# marker ages the whole chain so a churning worktree still re-surfaces once per
# PAUSE_RESURFACE_SECS. That only holds while the chain belongs to the CURRENT quiet
# stretch, so every path that restarts the idle-window timer must drop it too. The
# reachable case is a pane that deferred on write evidence and later has its timer
# repaired: a long-finished chain would make the first deferral of the new window
# re-surface immediately instead of after a fresh window.
test_timer_repair_drops_a_finished_write_deferral_chain() {
  local dir state fakebin out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-write-chain-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-chain-repair"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/chain-repair.meta"
  printf 'working: implementing\n' > "$state/chain-repair.status"
  sig=$(seen_sig "$state/chain-repair.status"); printf '%s' "$sig" > "$state/.seen-chain-repair_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  # A deferral chain left over from an earlier quiet stretch, already well past the
  # bounded re-surface window.
  back=$(( $(date +%s) - 5000 ))
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  # The idle-window timer is corrupt, so this poll repairs it and opens a NEW quiet
  # window without probing the worktree at all.
  printf 'corrupt\n' > "$state/.stale-since-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Watcher startup performs bounded recovery scans before its first stale poll;
  # give this positive marker assertion the same loaded-runner budget as the
  # suite's other startup-sensitive waits instead of failing after only 3s.
  wait_numeric_file "$state/.stale-since-$key" 100 \
    || { reap "$pid"; fail "the corrupt idle-window timer was not repaired"; }
  [ ! -e "$state/.writing-since-$key" ] \
    || { reap "$pid"; fail "an idle-window timer repair kept a finished write-deferral chain"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the idle-window timer repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional timer-repair watcher stop"

  # The new quiet window now crosses the escalation threshold while the crew writes
  # its worktree. That deferral must get a FRESH re-surface window rather than
  # inheriting the finished chain's age.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "the first deferral of a new quiet window re-surfaced at once, so it inherited a finished chain: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a fresh write deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a fresh write deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the new deferral recorded no chain marker"; }
  [ ! -e "$state/.writing-resurfaced-$key" ] \
    || { reap "$pid"; fail "a fresh write deferral spent its bounded re-surface on the first poll"; }
  reap "$pid"
  pass "an idle-window timer repair drops a finished write-deferral chain, so the next deferral gets a fresh re-surface window"
}

# The same chain must not outlive either first-sight path through a captain-relevant
# status line, because both also open a new idle window: the provably-working absorb
# and the plain surface.
test_terminal_first_sight_drops_a_finished_write_deferral_chain() {
  local dir state fakebin out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-write-chain-first-sight); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-chain-firstsight"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/chain-first.meta"
  printf 'done: implementation complete, ready to validate\n' > "$state/chain-first.status"
  sig=$(seen_sig "$state/chain-first.status"); printf '%s' "$sig" > "$state/.seen-chain-first_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 5000 ))
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # First sight of this hash, absorbed because the active run outranks the stale
  # captain-relevant line. The absorb opens a new idle window, so the finished chain
  # must go with it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the overridden terminal status was not absorbed on first sight: $(cat "$out")"
  fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "the first-sight absorb did not advance the stale suppressor"; }
  [ ! -e "$state/.writing-since-$key" ] \
    || { reap "$pid"; fail "the provably-working first-sight absorb kept a finished write-deferral chain"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional first-sight absorb stop"

  # Same pane, first sight again, but nothing overrides the status line now, so it
  # surfaces. That path drops the idle-window timer, so it must drop the chain too.
  rm -f "$state/.stale-$key" "$state/.stale-since-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run, no busy pane'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a first-sight captain-relevant status was not surfaced"
  grep -F "stale: $window" "$out" >/dev/null || fail "the first-sight surface did not print a stale wake"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the first-sight surface kept a finished write-deferral chain"
  unset FM_FAKE_CREW_STATE
  pass "both first-sight paths through a captain-relevant status drop a finished write-deferral chain with the idle window"
}

# --- the away-posture record: captain-held items are never rechecked ----------
# While state/.afk-contract exists (bin/fm-afk-contract.sh) nobody is there to
# answer a captain-held item and the return brief lists it, so every stale path
# absorbs such a pane silently: the declared-wait cadence, the live-agent first
# sight, the backlog-hold bound, and the daemon-owned one-shot handoff. Archiving
# the record restores the ordinary bounded recheck, so the rule is the record's,
# not a lost alarm.

test_captain_held_never_rechecked_while_away_record_exists() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case away-record-held-secondmate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  write_away_record "$state"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  # Phase A: the record exists, the hold is well past the cadence, and the
  # watcher still absorbs it across whole poll cycles: no wake, no throttle.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher rechecked a captain-held item while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a captain-held recheck was printed while the away-posture record exists"
  [ ! -s "$state/.wake-queue" ] || fail "a captain-held recheck was queued while the away-posture record exists"
  [ ! -e "$state/.paused-resurfaced-$key" ] || fail "the recheck throttle was armed for an item that must never be rechecked"
  grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null \
    || fail "the silent absorb did not name the away-posture rule in the triage log"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A stop"
  # Phase B: archiving the record (the return) restores the bounded recheck.
  archive_away_record "$state"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "archiving the away-posture record did not restore the captain-held recheck"; }
  grep -F "awaiting the captain" "$out" >/dev/null || fail "the restored recheck did not name the captain: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held item is never rechecked while the away-posture record exists, and the recheck returns once the record is archived"
}

# Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
# QUIET), so it silences nothing: the same hold is rechecked with that record
# live, both on the watcher's own cadence and through the one-shot handoff a
# running quiet daemon owns.
write_quiet_record() {  # <state>
  if ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1; then
    fail "could not write quiet mode's record in $1"
  fi
}

test_captain_held_rechecked_under_a_quiet_record() {
  local dir state fakebin out capture_file statusf window key back pid
  dir=$(make_case quiet-record-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf '%s' "$(hash_text "idle awaiting the captain")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  write_quiet_record "$state"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a captain-held item was not rechecked beside quiet mode's record"; }
  unset FM_FAKE_CREW_STATE
  grep -F "awaiting the captain" "$out" >/dev/null || fail "the recheck beside a quiet record did not name the captain: $(cat "$out")"
  ! grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null 2>&1 \
    || fail "quiet mode's record silenced a captain-held item as if the captain were away: $(cat "$state/.watch-triage.log")"
  [ -f "$state/.afk-contract" ] || fail "fixture: quiet mode's record is gone"
  ack_stopped_cycle "$state" || fail "could not acknowledge the captain-held recheck"

  dir=$(make_case quiet-daemon-held-oneshot); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-afk.status"
  window="test:fm-held-afk"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-afk.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-held-afk_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf 'quiet\n' > "$state/.afk"
  write_quiet_record "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the quiet daemon's one-shot never handed off a captain-held pane"; }
  grep -F "stale: $window" "$state/.wake-queue" >/dev/null \
    || fail "the quiet daemon's one-shot did not queue the captain-held pane for the daemon: $(cat "$state/.wake-queue" 2>/dev/null)"
  pass "quiet mode's record silences no captain-held recheck, on the watcher's cadence or through a quiet daemon's one-shot"
}

test_live_captain_held_first_sight_silenced_by_away_record() {
  local dir state fakebin out capture_file statusf window key sig pid
  dir=$(make_case away-record-held-live); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-live.status"
  window="test:fm-held-live"
  printf 'parked at the decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-live.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-live_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  write_away_record "$state"
  # A LIVE agent at the gate: without the record pause_state_class answers none
  # and the first sight surfaces (test_exited_declared_pause_is_bounded_but_live_gate_surfaces).
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a live captain-held pane surfaced on first sight while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a live captain-held pane was queued while the away-posture record exists"
  [ -e "$state/.stale-$key" ] || fail "the silenced first sight did not advance the stale suppressor"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a live captain-held pane is absorbed on first sight while the away-posture record exists"
}

test_backlog_hold_never_rechecked_while_away_record_exists() {
  local dir out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (away-record backlog hold)"; return 0; }
  dir=$(make_hold_home away-record-backlog-hold 'done: PR https://example.test/pr/9 checks green' hold) \
    || fail "could not build the backlog-hold fixture"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  write_away_record "$dir/state"
  # Without the record the FIRST sight of a held delivery alarms
  # (test_stale_churn_without_a_captain_call_still_alarms and its siblings). With
  # it, even the first sight and every later hash are absorbed.
  hold_watch_churn "$dir" "$out" "$capture" 'held delivery, pane tick' 3 \
    || fail "watcher exited while churning a backlog-held delivery under the away-posture record: $(cat "$out")"
  wakes=$(hold_stale_wakes "$dir/state")
  [ "$wakes" -eq 0 ] || fail "a backlog-held delivery was rechecked $wakes time(s) while the away-posture record exists"
  pass "a delivery the captain already holds is never rechecked while the away-posture record exists"
}

test_afk_one_shot_never_hands_off_captain_held_under_away_record() {
  local dir state fakebin out capture_file statusf window key sig pid
  dir=$(make_case away-record-held-afk-oneshot); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-afk.status"
  window="test:fm-held-afk"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-afk.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-afk_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  date '+%s' > "$state/.afk"
  write_away_record "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the daemon-owned one-shot handed off a captain-held pane while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the daemon-owned one-shot queued a captain-held pane while the away-posture record exists"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text 'idle awaiting the captain')" ] \
    || fail "the silenced one-shot did not advance the stale suppressor to the pane hash"
  reap "$pid"
  pass "the daemon-owned one-shot never hands off a captain-held pane while the away-posture record exists"
}

watch_triage_run_only

test_open_captain_call_bounds_stale_churn
test_stale_churn_without_a_captain_call_still_alarms
test_open_decision_bounds_stale_churn
test_failed_wake_append_does_not_arm_the_captain_hold_throttle
test_reheld_captain_call_starts_its_own_resurface_window
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_captain_held_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_secondmate_home_supervision_churn_is_not_write_evidence
test_timer_repair_drops_a_finished_write_deferral_chain
test_terminal_first_sight_drops_a_finished_write_deferral_chain
test_done_worker_with_recorded_pr_surfaces_once_then_absorbs_churn
test_done_worker_bound_ends_when_state_is_no_longer_done
test_done_worker_bound_ends_on_a_new_status_event
test_done_worker_without_recorded_pr_still_alarms_on_every_hash
test_captain_held_never_rechecked_while_away_record_exists
test_live_captain_held_first_sight_silenced_by_away_record
test_backlog_hold_never_rechecked_while_away_record_exists
test_afk_one_shot_never_hands_off_captain_held_under_away_record
test_captain_held_rechecked_under_a_quiet_record
