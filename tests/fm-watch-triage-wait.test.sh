#!/usr/bin/env bash
# tests/fm-watch-triage-wait.test.sh - the watcher's handling of declared
# waits: a declared pause absorbed then re-surfaced on its long cadence, pane
# churn under a declared wait, condition-aware `until` times, and a worker
# paused on its own background job.
# Shared fixtures and the family map live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional paused phase-A stop"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# Own background work is a declared wait using the same existing paused verb.
# This intentionally keeps the first-sight alert, then uses the long cadence.
# The backend/current-state fixtures are not live-harness evidence.
test_own_work_wait_keeps_first_alert_then_long_cadence() {
  local wait_kind dir state fakebin out capture_file statusf window key sig pid round
  for wait_kind in background-shell pipeline-run foreground-command; do
    dir=$(make_case "own-work-$wait_kind"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/own-work.status"
    window="test:fm-own-work"; key=$(printf '%s' "$window" | tr ':/.' '___')
    printf 'idle worker awaiting its own %s\n' "$wait_kind" > "$capture_file"
    printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/own-work.meta"
    printf 'paused: waiting for my %s to finish; resume on completion\n' "$wait_kind" > "$statusf"
    # Age before the first observation: backdating later can change the birth
    # time on macOS and accidentally turn this into a replacement declaration.
    set_mtime "$(( $(date +%s) - 500 ))" "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-own-work_status"
    printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"

    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting for own work' \
      watch_bg "$state" "$fakebin" "$out" env FM_PAUSE_RESURFACE_SECS=999
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "$wait_kind lost its first-sight alert"; }
    grep -Fx "stale: $window" "$out" >/dev/null || fail "$wait_kind did not surface as a plain stale"
    ack_stopped_cycle "$state" || fail "could not acknowledge $wait_kind first alert"

    # Cross the ordinary wedge threshold twice without aging the declaration
    # past the long pause cadence. Neither re-arm may add a second alert.
    for round in 1 2; do
      printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
      PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
        FM_FAKE_TMUX_CURRENT_COMMAND=grok \
        FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting for own work' \
        watch_bg "$state" "$fakebin" "$dir/recheck.out" env \
          FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999
      pid=$!
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$wait_kind repeated an alert: $(cat "$dir/recheck.out")"; }
      [ ! -s "$dir/recheck.out" ] || { reap "$pid"; fail "$wait_kind printed a repeated alert"; }
      [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "$wait_kind queued a repeated alert"; }
      [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "$wait_kind counted a wedge"; }
      reap "$pid"
      ack_stopped_cycle "$state" || fail "could not acknowledge $wait_kind test stop"
    done

    # Both the unchanged declaration and its first alert must be older than
    # the 240s cadence for a forgotten wait to get its bounded recheck.
    set_mtime "$(( $(date +%s) - 500 ))" "$state/.paused-resurfaced-$key"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=grok \
      FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting for own work' \
      watch_bg "$state" "$fakebin" "$dir/long-cadence.out" env \
        FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240
    pid=$!
    wait_for_exit "$pid" 100 || { reap "$pid"; fail "$wait_kind never rechecked on the long cadence"; }
    grep -F 'awaiting external' "$dir/long-cadence.out" >/dev/null || fail "$wait_kind recheck lost its pause reason"
    grep -F 'possible wedge' "$dir/long-cadence.out" >/dev/null && fail "$wait_kind recheck became a wedge"
  done
  # Disconfirming control: an idle worker with no declaration must still alarm.
  dir=$(make_case own-work-undeclared); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/own-work.status"
  printf 'idle worker without a declared wait\n' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/own-work.meta"
  printf 'working: implementing\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-own-work_status"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_bg "$state" "$fakebin" "$out" env FM_STALE_ESCALATE_SECS=999
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "undeclared idle worker no longer alarms"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "undeclared idle worker did not surface"
  grep -F "stale: $window" "$state/.wake-queue" >/dev/null || fail "undeclared idle worker's wake was not queued"
  pass "own-work waits keep one first alert, then bounded rechecks without wedges; undeclared idle still alarms"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_poll_cycle "$state" "$pid"; then
      reap "$pid"
    elif kill -0 "$pid" 2>/dev/null; then
      reap "$pid"
      fail "dead-agent watcher round $round timed out before completing a poll cycle"
    else
      wait "$pid" || fail "dead-agent watcher round $round failed"
    fi
    round=$((round + 1))
  done
  # A watcher that queues nothing never creates .wake-queue, so these counts
  # read a path that may legitimately be absent. awk aborts on a missing file
  # before END runs, which collapses the count to the empty string and turns the
  # next comparison into an "integer expression expected" error - reported as a
  # flood of an unprintable number of wakes instead of the real contract breach
  # the grep below names. No queue means no wakes, per the drain-count read at
  # the end of this file.
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting the captain" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew instead of a captain-owned recheck: $(cat "$state/.wake-queue")"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    && fail "captain-held dead-agent pane borrowed the pause verb's external-wait wording"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "live external-decision gate did not surface immediately"
  ack_stopped_cycle "$state" || fail "could not acknowledge the immediate external-decision surface"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "acknowledged external-decision surface replayed $wakes wakes"
  [ "$bare" -eq 0 ] || fail "acknowledged external-decision bare stale remained queued"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

# A dead worker reaches handle_paused_stale rather than the live fallback above.
# When one declared wait directly replaces another, the existing
# throttle belongs to the old declaration and must not suppress the new wait's
# first inspection merely because its timestamp is still young.
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle() {
  local spec name initial replacement expected dir state fakebin out capture_file
  local statusf window key sig back pid wakes
  for spec in \
    'paused-replacement|paused: waiting on validation run one|paused: waiting on validation run two|awaiting external' \
    'captain-held-replacement|captain-held [key=route]: awaiting the routing call|captain-held [key=release]: awaiting the release call|awaiting the captain'
  do
    name=${spec%%|*}; spec=${spec#*|}
    initial=${spec%%|*}; spec=${spec#*|}
    replacement=${spec%%|*}; expected=${spec#*|}
    dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
    window="test:fm-held"
    printf 'idle after agent exit\n' > "$capture_file"
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
    printf '%s\n' "$initial" > "$statusf"
    back=$(( $(date +%s) - 500 ))
    if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
    else touch -m -d "@$back" "$statusf"; fi
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    printf '%s' "$(hash_text 'idle after agent exit')" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"

    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "[$name] initial declared wait did not re-surface"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the initial declared wait"

    printf '%s\n' "$replacement" >> "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    printf 'idle after replacement wait\n' > "$capture_file"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_for_exit "$pid" 100 \
      || { reap "$pid"; fail "[$name] replacement declared wait inherited the old throttle"; }
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] replacement declared wait produced $wakes wakes instead of one"
    grep -F "$expected" "$state/.wake-queue" >/dev/null \
      || fail "[$name] replacement declared wait used the wrong recheck reason: $(cat "$state/.wake-queue")"
  done
  pass "absorbed paused and captain-held replacements each start their own re-surface cadence"
}

# --- a live worker parked on a declared wait: pane churn must not re-alarm ----
# The 2026-08/09 alarm loop, in both observed forms - a worker parked on the
# CAPTAIN (captain-held, five consecutive alarms) and one parked on the PIPELINE
# (paused:, dozens across one day). pause_state_class deliberately returns `none`
# for either while the agent is still ALIVE, so that a worker genuinely waiting on
# a decision is never silenced; first sight of each distinct stale hash therefore
# reaches surface_nonterminal_stale. An idle parked pane still churns its hash (a
# clock, a token counter), so every tick used to re-enter that first-sight path and
# wake firstmate - the throttle was written by the very wake it should have
# prevented, and the hash-change path cleared it again before it was ever read.
# The contract pinned here: the FIRST sight still surfaces, further sights inside
# PAUSE_RESURFACE_SECS are absorbed, and the window's end still re-surfaces once,
# so a forgotten wait cannot rot invisibly.
test_live_declared_wait_churn_honors_the_resurface_throttle() {
  local spec name status_line dir state fakebin out capture_file statusf window key
  local sig round wakes bare text throttle replacement
  for spec in \
    'paused-pipeline-churn|paused: waiting on the validation run to finish' \
    'captain-held-churn|captain-held [key=route]: awaiting the captain on the routing call'
  do
    name=${spec%%|*}; status_line=${spec#*|}
    dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/parked.status"
    window="test:fm-parked"
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
    printf '%s\n' "$status_line" > "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    throttle="$state/.paused-resurfaced-$key"

    # First sight of a parked-but-live worker must still surface: the state is
    # inconclusive and firstmate has to look at it.
    text='parked, elapsed 1s'
    printf '%s' "$text" > "$capture_file"
    printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
      || fail "[$name] first sight of a parked live worker did not surface"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the first surface"
    [ -e "$throttle" ] || fail "[$name] the first surface recorded no re-surface throttle"

    # The pane now churns while the SAME declared wait stands, each round fully
    # handled as a real supervision turn would. Every one of these used to alarm.
    round=2
    while [ "$round" -le 4 ]; do
      printf 'parked, elapsed %ss' "$round" > "$capture_file"
      parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
        || fail "[$name] watcher exited during churn round $round instead of supervising through it"
      wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
        "$state/.wake-queue" 2>/dev/null || echo 0)
      [ "$wakes" -eq 0 ] \
        || fail "[$name] pane churn re-alarmed a parked worker $wakes time(s) inside the re-surface window"
      [ -e "$throttle" ] || fail "[$name] pane churn cleared the re-surface throttle"
      round=$((round + 1))
    done

    # A direct wait-to-wait transition starts a NEW declaration even though the
    # same window remains parked. Its first sight must not inherit the previous
    # declaration's throttle, or an unrelated replacement wait can stay silent
    # for nearly the whole old cadence window.
    case "$name" in
      paused-pipeline-churn) replacement='paused: waiting on the replacement validation run' ;;
      captain-held-churn) replacement='captain-held [key=release]: awaiting the captain on the release call' ;;
    esac
    printf '%s\n' "$replacement" >> "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
    printf 'replacement wait, elapsed 1s' > "$capture_file"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
      || fail "[$name] a replacement declared wait inherited the previous wait's re-surface throttle"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] replacement declared wait produced $wakes first wakes instead of one"
    [ "$bare" -eq 1 ] || fail "[$name] replacement declared wait changed the wake identity: $(cat "$state/.wake-queue")"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the replacement wait's first surface"

    printf 'replacement wait, elapsed 2s' > "$capture_file"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
      || fail "[$name] replacement wait re-alarmed inside its own re-surface window"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 0 ] || fail "[$name] replacement wait re-alarmed $wakes time(s) inside its own re-surface window"

    # End of the window: the wait must re-surface exactly once, on the same plain
    # identity as before, so absorbing churn never becomes silence.
    set_mtime "$(( $(date +%s) - 2000 ))" "$throttle"
    printf 'parked, elapsed 5s' > "$capture_file"
    parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
      || fail "[$name] a parked worker did not re-surface once its re-surface window elapsed"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] elapsed re-surface window produced $wakes wakes instead of one"
    [ "$bare" -eq 1 ] || fail "[$name] elapsed re-surface changed the wake identity: $(cat "$state/.wake-queue")"
  done
  pass "a parked live worker surfaces once, absorbs pane churn for the whole re-surface window, then re-surfaces when it elapses"
}

# A paused worker reacting to its own background job turns its pane busy for a
# moment, then idles again with nothing new to say. That busy phase must not
# erase the declared wait's re-surface throttle, or every busy-then-idle cycle
# re-alarms the same declaration as a new first sight (the 2026-10-05 loop: a
# worker paused on its benchmark runs woke supervision four times in six
# minutes). A new declaration still starts its own window.
test_busy_cycle_keeps_the_declared_pause_throttle() {
  local dir state fakebin out capture_file statusf window key sig wakes throttle
  dir=$(make_case paused-busy-cycle); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/parked.status"
  window="test:fm-parked"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  printf 'paused: waiting on two benchmark runs\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  throttle="$state/.paused-resurfaced-$key"

  printf 'parked, elapsed 1s' > "$capture_file"
  printf '%s' "$(hash_text 'parked, elapsed 1s')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
    || fail "first sight of a paused live worker did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first surface"
  [ -e "$throttle" ] || fail "the first surface recorded no re-surface throttle"

  # The worker wakes on its background job: the pane is busy for several polls.
  printf 'benchmark finished, reading results\nCtrl+c:cancel' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "watcher exited while the paused worker was busy"
  [ -e "$throttle" ] || fail "a busy phase erased the declared pause's re-surface throttle"

  # Back to idle on a new hash, with the same declaration standing.
  printf 'parked, waiting on the second run' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "the same declared pause re-alarmed after a busy-then-idle cycle"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "a busy-then-idle cycle re-alarmed the same pause $wakes time(s)"

  # A new declaration is a new first sight, busy phase or not.
  printf 'paused: waiting on the rerun\n' >> "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  printf 'parked, waiting on the rerun' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
    || fail "a new pause declaration inherited the old declaration's throttle"
  pass "a busy-then-idle cycle keeps a declared pause's re-surface throttle, while a new declaration surfaces"
}

test_live_paused_until_controls_recheck_time() {
  local dir state fakebin out capture_file statusf window key sig wakes future past
  dir=$(make_case live-paused-until); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/parked.status"
  window="test:fm-parked"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  future=$(iso_utc_at "$(( $(date +%s) + 7200 ))")
  printf 'paused: rate limit until %s\n' "$future" > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'parked, elapsed 1s' > "$capture_file"
  printf '%s' "$(hash_text 'parked, elapsed 1s')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "a live worker woke before its declared future time"
  printf 'parked, elapsed 2s' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "pane churn bypassed a live worker's declared future time"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "a live worker produced $wakes wakes before its declared time"

  past=$(iso_utc_at "$(( $(date +%s) - 120 ))")
  printf 'paused: rate limit until %s\n' "$past" >> "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  printf 'parked, elapsed 3s' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" exit \
    || fail "a live worker did not wake when its declared time passed"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 1 ] || fail "a passed declared time produced $wakes wakes instead of one"
  ack_stopped_cycle "$state" || fail "could not acknowledge the due declared-time recheck"
  printf 'parked, elapsed 4s' > "$capture_file"
  parked_watch_round "$state" "$fakebin" "$out" "$capture_file" "$window" absorb \
    || fail "a due declared time bypassed the reset long cadence"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "a due declared time rechecked again inside the long cadence"
  pass "a live paused worker stays absorbed until its declared time, then rechecks"
}

# --- declared waits are condition-aware: `until <UTC ISO 8601>` --------------
# A paused: line naming when the wait clears is rechecked at that time when it
# falls within the flat cadence, but a distant or mistyped time cannot extend
# the cadence, and a time that has passed is rechecked at once.
paused_until_fixture() {  # <name> <until-epoch> <status-age-secs>
  local name=$1 until=$2 age=$3 dir state statusf window key back
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-until"
  statusf="$state/until.status"
  printf 'idle, waiting for the reset\n' > "$dir/pane.txt"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/until.meta"
  printf 'paused: rate limit resets, until %s, then resuming\n' "$(iso_utc_at "$until")" > "$statusf"
  back=$(( $(date +%s) - age ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-until_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  printf '%s' "$(hash_text 'idle, waiting for the reset')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

until_watch() {  # <dir> <cadence> -> pid in UNTIL_PID
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-until FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="$2" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  UNTIL_PID=$!
}

test_paused_until_near_future_is_quiet_before_the_cadence() {
  local dir state
  dir=$(paused_until_fixture until-near-future "$(( $(date +%s) + 120 ))" 60); state="$dir/state"
  until_watch "$dir" 240
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "a declared wait with a near-future until time was rechecked before that time: $(cat "$dir/watch.out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a declared wait with a near-future until time was queued for a recheck"
  grep -F 'declared time not reached' "$state/.watch-triage.log" >/dev/null \
    || fail "the absorb did not cite the declared time in the triage log"
  reap "$UNTIL_PID"
  pass "a declared wait naming a near-future until time stays quiet until that time"
}

test_paused_until_wrong_year_is_bounded_by_the_cadence() {
  local dir state
  dir=$(paused_until_fixture until-wrong-year "$(( $(date +%s) + 31536000 ))" 300); state="$dir/state"
  until_watch "$dir" 240
  wait_for_exit "$UNTIL_PID" 100 \
    || { reap "$UNTIL_PID"; fail "a wrong-year declared time silenced the wait beyond the recheck cadence"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null \
    || fail "the bounded wrong-year recheck did not print a stale wake: $(cat "$dir/watch.out")"
  grep -F 'declared time is beyond the recheck cadence' "$dir/watch.out" >/dev/null \
    || fail "the bounded recheck gave the wrong reason: $(cat "$dir/watch.out")"
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null \
    && fail "the bounded recheck falsely claimed the future declared time passed"
  pass "a wrong-year declared time cannot silence the watcher beyond the recheck cadence"
}

test_paused_until_that_passed_is_rechecked_before_the_cadence() {
  local dir state
  dir=$(paused_until_fixture until-passed "$(( $(date +%s) - 30 ))" 60); state="$dir/state"
  until_watch "$dir" 999
  wait_for_exit "$UNTIL_PID" 100 || { reap "$UNTIL_PID"; fail "a declared wait whose until time passed was not rechecked ahead of the cadence"; }
  grep -F 'stale: test:fm-until' "$dir/watch.out" >/dev/null || fail "the due recheck did not print a stale wake: $(cat "$dir/watch.out")"
  grep -F 'declared clearing time has passed' "$dir/watch.out" >/dev/null \
    || fail "the due recheck did not say the declared time passed: $(cat "$dir/watch.out")"
  grep -F 'possible wedge' "$dir/watch.out" >/dev/null && fail "a due declared wait was mislabeled a possible wedge"
  # The due recheck fires once per declaration: a second watcher on the same
  # unchanged declaration absorbs it again.
  ack_stopped_cycle "$state" || fail "could not acknowledge the due recheck"
  : > "$dir/watch.out"
  until_watch "$dir" 999
  if ! wait_poll_cycle "$state" "$UNTIL_PID" || ! wait_poll_cycle "$state" "$UNTIL_PID"; then
    reap "$UNTIL_PID"; fail "the due recheck repeated on every poll instead of once per declaration: $(cat "$dir/watch.out")"
  fi
  reap "$UNTIL_PID"
  pass "a declared wait whose until time has passed is rechecked at once, then held to the cadence"
}

# The scheduled fleet sync queues its new STUCK lines in state/fleet-sync-stuck;
# the watcher claims them as one actionable check wake.
test_fleet_sync_stuck_lines_surface_as_one_check_wake() {
  local dir state out pid
  dir=$(make_case fleet-sync-stuck); state="$dir/state"; out="$dir/watch.out"
  printf '%s\n' 'alpha: STUCK: on branch main with uncommitted changes, 1 commits behind origin/main - needs attention' \
    'svc live /srv/svc: STUCK: post-update command failed (exit 3) at abc1234; the next sync retries it - needs attention; last output: boom' \
    > "$state/fleet-sync-stuck"
  watch_bg "$state" "$dir/fakebin" "$out" env FM_FLEET_SYNC_INTERVAL=off
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not exit on queued fleet-sync STUCK lines: $(cat "$out")"
  grep -F 'check: fleet-sync: alpha: STUCK: on branch main' "$out" >/dev/null \
    || fail "the wake did not name the first STUCK line: $(cat "$out")"
  grep -F ' | svc live /srv/svc: STUCK: post-update command failed (exit 3)' "$out" >/dev/null \
    || fail "the wake did not carry every STUCK line in one reason: $(cat "$out")"
  grep "$(printf '\tcheck\tfleet-sync\t')" "$state/.wake-queue" >/dev/null \
    || fail "the fleet-sync wake was not queued durably: $(cat "$state/.wake-queue")"
  [ ! -e "$state/fleet-sync-stuck" ] && [ ! -e "$state/.fleet-sync-stuck.claimed" ] \
    || fail "the claimed STUCK lines were left behind for a second wake"
  pass "queued fleet-sync STUCK lines surface once as a single check: fleet-sync wake"
}

# A due schedule starts the whole-fleet sync detached; the first sighting with
# no marker only starts the cadence.
test_fleet_sync_schedule_runs_the_sync_when_due() {
  local dir state out pid work origin clone i
  dir=$(make_case fleet-sync-schedule); dir=$(cd "$dir" && pwd -P); state="$dir/state"; out="$dir/watch.out"
  work="$dir/work"; origin="$dir/origin.git"; clone="$dir/projects/beta"
  fm_git_init_commit "$work"
  git clone --quiet --bare "$work" "$origin"
  mkdir -p "$dir/projects" "$dir/data"
  printf -- '- beta [direct-PR] - test project (added 2026-10-06)\n' > "$dir/data/projects.md"
  git clone --quiet "file://$origin" "$clone"
  printf 'next\n' > "$work/next.txt"
  git -C "$work" add next.txt
  git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -qm next
  git -C "$work" push -q "file://$origin" main

  # fm-fleet-sync.sh resolves the registry helper from FM_ROOT_OVERRIDE, so this
  # case points it at the real checkout instead of the suite's tangle fixture.
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_FLEET_SYNC_INTERVAL=300 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "the watcher exited before a full cycle: $(cat "$out")"
  [ -e "$state/.last-fleet-sync" ] || { reap "$pid"; fail "the first sighting did not start the cadence"; }
  [ ! -e "$state/.fleet-sync-scheduled.log" ] || { reap "$pid"; fail "the first sighting ran a sync"; }

  touch -t 200001010000 "$state/.last-fleet-sync"
  i=0
  while [ "$i" -lt 150 ] && [ "$(git -C "$clone" rev-parse HEAD)" != "$(git -C "$work" rev-parse HEAD)" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" || fail "a clean scheduled sync woke the watcher: $(cat "$out")"
  reap "$pid"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$work" rev-parse HEAD)" ] \
    || fail "the due schedule did not fast-forward the clone: $(cat "$state/.fleet-sync-scheduled.log" 2>&1)"
  [ ! -e "$state/.wake-queue" ] || [ ! -s "$state/.wake-queue" ] || fail "a clean sync queued a wake: $(cat "$state/.wake-queue")"
  pass "a due schedule runs the whole-fleet sync without waking firstmate when nothing is stuck"
}

# Default releases recorded by the detached release scan queue their own durable
# rows and leave their lines in state/hold-release-woke; the watcher claims them
# as one check wake.
test_hold_release_lines_surface_as_one_check_wake() {
  local dir state out pid
  dir=$(make_case hold-release-woke); state="$dir/state"; out="$dir/watch.out"
  printf '%s\n' 'released by default: sample-call drop it' \
    'released by default: sample-other ship now' > "$state/hold-release-woke"
  watch_bg "$state" "$dir/fakebin" "$out" env FM_FLEET_SYNC_INTERVAL=off FM_HOLD_RELEASE_INTERVAL=off
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not exit on queued default releases: $(cat "$out")"
  grep -F 'check: released by default: sample-call drop it (and 1 more released by default)' "$out" >/dev/null \
    || fail "the wake did not name the first release and count the rest: $(cat "$out")"
  grep "$(printf '\tcheck\thold-release-sample-call\t')" "$state/.wake-queue" >/dev/null \
    || fail "the first release was not queued as its own durable row: $(cat "$state/.wake-queue" 2>&1)"
  grep "$(printf '\tcheck\thold-release-sample-other\t')" "$state/.wake-queue" >/dev/null \
    || fail "the second release was not queued as its own durable row: $(cat "$state/.wake-queue" 2>&1)"
  [ ! -e "$state/hold-release-woke" ] && [ ! -e "$state/.hold-release-woke.claimed" ] \
    || fail "the claimed release lines were left behind for a second wake"
  pass "queued default-release lines surface once as a single check wake"
}

# A due schedule runs the release scan detached against this home: a reversible
# default past its 72 hours is recorded, queued durably, and wakes the watcher.
test_hold_release_schedule_releases_a_due_default() {
  local dir state out pid show
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  dir=$(make_case hold-release-schedule); dir=$(cd "$dir" && pwd -P); state="$dir/state"; out="$dir/watch.out"
  mkdir -p "$dir/data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CAPTAIN_HOLD_NOW=2020-01-01T00:00:00Z \
    "$ROOT/bin/fm-captain-hold.sh" hold sample-call --title "Keep the banner" \
    --reason "keep or drop" --kind reversible --default "drop it" >/dev/null \
    || fail "could not hold the reversible call"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_FLEET_SYNC_INTERVAL=off \
    FM_HOLD_RELEASE_INTERVAL=1 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_poll_cycle "$state" "$pid" || fail "the watcher exited before a full cycle: $(cat "$out")"
  [ -e "$state/.last-hold-release" ] || { reap "$pid"; fail "the first sighting did not start the cadence"; }
  touch -t 200001010000 "$state/.last-hold-release"
  wait_for_exit "$pid" 150 || fail "the watcher did not wake on a due default release: $(cat "$out")"
  grep -F 'check: released by default: sample-call drop it' "$out" >/dev/null \
    || fail "the wake did not name the release: $(cat "$out")"
  grep "$(printf '\tcheck\thold-release-sample-call\t')" "$state/.wake-queue" >/dev/null \
    || fail "the release was not queued durably: $(cat "$state/.wake-queue" 2>&1)"
  show=$(FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" show sample-call --full)
  assert_contains "$show" "Resolution mode: defaulted" "the scheduled release left no record"
  pass "a due schedule releases a reversible default and wakes the watcher"
}

# A captain inbox note whose first wake was drained but which nobody
# acknowledged re-wakes the watcher once it is due; an acknowledged one never
# does. FM_INBOX_REWAKE_SECONDS shrinks the day so the case runs in seconds.
inbox_rewake_watch() {  # <dir> <out>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CREW_STATE_BIN="$1/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_FLEET_SYNC_INTERVAL=off FM_HOLD_RELEASE_INTERVAL=off \
    FM_INBOX_REWAKE_INTERVAL=1 FM_INBOX_REWAKE_SECONDS=1 "$WATCH" > "$2" 2>/dev/null &
}

inbox_rewake_case() {  # <name> -> "<dir> <note-id>"
  local dir err id
  dir=$(make_case "$1"); dir=$(cd "$dir" && pwd -P)
  id=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-inbox.sh" note "look at the retro") \
    || fail "could not queue the inbox note"
  id=${id#queued }
  id=${id%%$'\n'*}
  err="$dir/drain.err"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$err" \
    || fail "could not drain the note's first wake: $(cat "$err")"
  ack_drain_err "$dir/state" "$err" >/dev/null 2>&1 || fail "could not acknowledge the drained wake"
  sleep 2
  printf '%s %s\n' "$dir" "$id"
}

test_unacknowledged_inbox_note_rewakes_the_watcher() {
  local dir id out pid
  read -r dir id <<EOF
$(inbox_rewake_case inbox-rewake)
EOF
  out="$dir/watch.out"
  inbox_rewake_watch "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the watcher did not wake on a due inbox note: $(cat "$out")"; }
  grep -F 'check: captain inbox: 1 note(s) still unacknowledged (bin/fm-inbox.sh unread)' "$out" >/dev/null \
    || fail "the wake did not name the unacknowledged note count: $(cat "$out")"
  grep "$(printf '\tcheck\tinbox:%s\t' "$id")" "$dir/state/.wake-queue" >/dev/null \
    || fail "the re-wake was not queued durably for the note: $(cat "$dir/state/.wake-queue" 2>&1)"
  pass "an unacknowledged inbox note re-wakes the watcher once it is due"
}

test_acknowledged_inbox_note_never_rewakes_the_watcher() {
  local dir id out pid
  read -r dir id <<EOF
$(inbox_rewake_case inbox-acked)
EOF
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-inbox.sh" drain --ack "$id" >/dev/null \
    || fail "could not acknowledge the note"
  out="$dir/watch.out"
  inbox_rewake_watch "$dir" "$out"
  pid=$!
  wait_poll_cycle "$dir/state" "$pid" || fail "the watcher exited before a full cycle: $(cat "$out")"
  [ -e "$dir/state/.last-inbox-rewake" ] || { reap "$pid"; fail "the re-wake scan never ran"; }
  wait_poll_cycle "$dir/state" "$pid" || fail "an acknowledged note woke the watcher: $(cat "$out")"
  reap "$pid"
  pass "an acknowledged inbox note never re-wakes the watcher"
}

# Lines a detached overdue scan left behind are claimed once as one wake.
test_overdue_scan_lines_surface_as_one_check_wake() {
  local dir state out pid
  dir=$(make_case backlog-overdue-woke); state="$dir/state"; out="$dir/watch.out"
  printf '%s\n' 'overdue price-ladder' 'overdue restock' > "$state/backlog-overdue-woke"
  watch_bg "$state" "$dir/fakebin" "$out" env FM_FLEET_SYNC_INTERVAL=off FM_HOLD_RELEASE_INTERVAL=off \
    FM_BACKLOG_OVERDUE_INTERVAL=off
  pid=$!
  wait_for_exit "$pid" 100 || fail "the watcher did not exit on pending overdue lines: $(cat "$out")"
  grep -F 'check: backlog overdue: 2 dated item(s) past their gate' "$out" >/dev/null \
    || fail "the wake did not count the overdue lines: $(cat "$out")"
  [ ! -e "$state/backlog-overdue-woke" ] && [ ! -e "$state/.backlog-overdue-woke.claimed" ] \
    || fail "the claimed overdue lines were left behind for a second wake"
  pass "pending overdue scan lines surface once as a single check wake"
}

# A sitting that comes due with a call waiting wakes the watcher through the
# durable row the detached check queues, with no second hand-off to claim.
test_due_decision_sitting_wakes_the_watcher() {
  local dir state out pid snap
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  dir=$(make_case decision-sitting); dir=$(cd "$dir" && pwd -P); state="$dir/state"; out="$dir/watch.out"
  snap="$dir/snapshot.json"
  jq -n '{backlog:{records:[{id:"pick-plan",structured:true,state:"queued",hold_kind:"captain",
    hold_bucket:"live",hold_reason:"[reversible] pick a plan"}]}}' > "$snap"
  # 2026-11-01 12:00 New York is 17:00Z; the previous sitting was 2026-10-31 20:00.
  printf '1793491200\n' > "$state/.last-decision-sitting"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_FLEET_SYNC_INTERVAL=off FM_HOLD_RELEASE_INTERVAL=off \
    FM_INBOX_REWAKE_INTERVAL=off FM_BACKLOG_OVERDUE_INTERVAL=off FM_DECISION_SITTING_INTERVAL=1 \
    FM_DECISION_SITTING_NOW=1793552460 FM_DECISION_SITTING_SNAPSHOT="$snap" "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the watcher did not wake on a due sitting: $(cat "$out")"; }
  grep -F 'check: queued work: 1 check' "$out" >/dev/null \
    || fail "the wake did not surface the queued sitting row: $(cat "$out")"
  grep "$(printf '\tcheck\tdecision-sitting:1793552400\t')" "$state/.wake-queue" >/dev/null \
    || fail "the due sitting was not queued durably: $(cat "$state/.wake-queue" 2>&1)"
  [ ! -e "$state/decision-sitting-woke" ] || fail "the sitting left a second hand-off file to claim"
  pass "a due decision sitting wakes the watcher once through its durable row"
}

# A queued backlog item whose date gate lapsed long ago without a dispatch
# wakes the watcher through the detached overdue scan, which queues its durable row.
test_overdue_backlog_item_wakes_the_watcher() {
  local dir state out pid
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  dir=$(make_case backlog-overdue); dir=$(cd "$dir" && pwd -P); state="$dir/state"; out="$dir/watch.out"
  mkdir -p "$dir/data" "$dir/config"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add price-ladder --title "Run the price ladder" >/dev/null \
    || fail "could not file the dated item"
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" hold price-ladder --reason "run on the day" \
    --kind future --until 2020-01-03 >/dev/null \
    || fail "could not date the item"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_FLEET_SYNC_INTERVAL=off FM_HOLD_RELEASE_INTERVAL=off \
    FM_INBOX_REWAKE_INTERVAL=off FM_BACKLOG_OVERDUE_INTERVAL=1 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the watcher did not wake on an overdue item: $(cat "$out")"; }
  # The detached scan queues the row itself; whichever tick sees it first wakes.
  grep -E 'check: (backlog overdue: 1 dated item|queued work: 1 check)' "$out" >/dev/null \
    || fail "the wake did not surface the overdue item: $(cat "$out")"
  grep "$(printf '\tcheck\tbacklog-overdue:price-ladder\t')" "$state/.wake-queue" >/dev/null \
    || fail "the overdue item was not queued durably: $(cat "$state/.wake-queue" 2>&1)"
  pass "an overdue dated backlog item wakes the watcher once through its durable row"
}

# --- a live worker paused on its own background job --------------------------
# A worker declared `paused:` on its own background job and the job then ended
# without a new status line, so only the passage of time can tell the watcher
# the wait should be over. Without `until`, the first-sight alert spends the
# declaration's re-surface throttle and every later sight - including the one
# after the job ended - is held for PAUSE_RESURFACE_SECS. Naming the job's
# start plus its timeout as `until` gives that same declaration one recheck once
# the job can no longer be running.
bg_job_paused_case() {  # <name> <status-line> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"; window="test:fm-parked"
  printf 'window=%s\nkind=scout\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  printf '%s\n' "$2" > "$state/parked.status"
  printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'nightly build running' > "$dir/pane.txt"
  printf '%s' "$(hash_text 'nightly build running')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

bg_job_stale_wakes() {  # <state> -> count of stale wakes queued for the parked window
  awk -F '\t' '$3 == "stale" && $4 == "test:fm-parked" { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

test_paused_bg_job_without_until_stays_silent_after_the_job_ends() {
  local dir state
  dir=$(bg_job_paused_case bg-job-no-until \
    "paused [key=nightly-build] [at=$(date +%s)]: nightly build; resume when the job finishes")
  state="$dir/state"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked exit \
    || fail "first sight of a worker paused on its background job did not surface"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first-sight alert"
  printf '[bg failed] nightly build - Exited with code 1' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "the ended job surfaced although the declaration names no time"
  [ "$(bg_job_stale_wakes "$state")" -eq 0 ] \
    || fail "the ended job surfaced inside the cadence although the declaration names no time"
  pass "without until, a worker paused on its own ended background job is not rechecked inside the cadence"
}

test_paused_bg_job_until_timeout_rechecks_after_the_job_ends() {
  local dir state started
  started=$(date +%s)
  dir=$(bg_job_paused_case bg-job-until-running \
    "paused [key=nightly-build] [at=$started]: nightly build (background job, 600s timeout); resume when it ends, until $(iso_utc_at "$(( started + 600 ))")")
  state="$dir/state"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "a worker paused on its running background job woke before the job's timeout"
  [ "$(bg_job_stale_wakes "$state")" -eq 0 ] || fail "the running job surfaced before its timeout"
  started=$(( $(date +%s) - 180 ))
  dir=$(bg_job_paused_case bg-job-until \
    "paused [key=nightly-build] [at=$started]: nightly build (background job, 120s timeout); resume when it ends, until $(iso_utc_at "$(( started + 120 ))")")
  state="$dir/state"
  printf '[bg failed] nightly build - Exited with code 1' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked exit \
    || fail "the job's timeout passed without a recheck of the worker paused on it"
  [ "$(bg_job_stale_wakes "$state")" -eq 1 ] || fail "the passed timeout queued the wrong number of rechecks"
  awk -F '\t' '$3 == "stale" && $5 == "stale: test:fm-parked" { found = 1 } END { exit !found }' \
    "$state/.wake-queue" || fail "the recheck carried an unexpected reason: $(cat "$state/.wake-queue")"
  case "$(cat "$state/.paused-resurfaced-test_fm-parked" 2>/dev/null)" in
    *:due) ;;
    *) fail "the recheck was not recorded as the passed declared time" ;;
  esac
  ack_stopped_cycle "$state" || fail "could not acknowledge the due recheck"
  printf '[bg failed] nightly build - Exited with code 1 (idle)' > "$dir/pane.txt"
  parked_watch_round "$state" "$dir/fakebin" "$dir/watch.out" "$dir/pane.txt" test:fm-parked absorb \
    || fail "the due recheck repeated instead of returning to the cadence"
  pass "until set to a background job's timeout rechecks the worker paused on it once the job must have ended"
}

watch_triage_run_only

test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_own_work_wait_keeps_first_alert_then_long_cadence
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle
test_live_declared_wait_churn_honors_the_resurface_throttle
test_busy_cycle_keeps_the_declared_pause_throttle
test_live_paused_until_controls_recheck_time
test_paused_until_near_future_is_quiet_before_the_cadence
test_paused_until_wrong_year_is_bounded_by_the_cadence
test_paused_until_that_passed_is_rechecked_before_the_cadence
test_fleet_sync_stuck_lines_surface_as_one_check_wake
test_fleet_sync_schedule_runs_the_sync_when_due
test_hold_release_lines_surface_as_one_check_wake
test_hold_release_schedule_releases_a_due_default
test_unacknowledged_inbox_note_rewakes_the_watcher
test_acknowledged_inbox_note_never_rewakes_the_watcher
test_overdue_scan_lines_surface_as_one_check_wake
test_due_decision_sitting_wakes_the_watcher
test_overdue_backlog_item_wakes_the_watcher
test_paused_bg_job_without_until_stays_silent_after_the_job_ends
test_paused_bg_job_until_timeout_rechecks_after_the_job_ends
