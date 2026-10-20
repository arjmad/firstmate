#!/usr/bin/env bash
# tests/fm-watch-triage-stale.test.sh - the watcher's stale-pane triage:
# terminal-looking status overridden by an active run, provably-working panes
# absorbed then wedge-escalated, consecutive escalations demanding inspection,
# gone endpoints, opt-in operator guards, the busy-pane duration bound, worktree
# write and process deferrals, and the Claude exit picker.
# Shared fixtures and the family map live in tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- a record whose agent is GONE reports once, instead of alarming forever ---
# Observed on a live fleet: two finished lanes reached 226 and 203 CONSECUTIVE
# wedge escalations, one alarm roughly every FM_STALE_ESCALATE_SECS, indefinitely -
# from lanes with no agent running at all. `bin/fm-control.sh <id> exit` answered
# `already-stopped` and `bin/fm-crew-state.sh` read `failed - run failed`. Closing
# the pane did not stop it either: with the pane gone (`herdr pane read` ->
# `pane_not_found`) the count still climbed, because the poll is driven by the
# durable record's `window=` line, not by the pane. The escalate path clears its
# own idle timer and re-arms with nothing bounding the count, and a dead agent's
# pane never churns to reset it, so the ladder had no ceiling. The cost is not the
# repetition: it is that ~400 notifications a day from two finished lanes drown
# the alarms that matter, and the captain stopped reading them.
#
# fm_backend_agent_state already separated an agent that is THINKING from one that
# is gone; the escalation path simply never asked it. Both directions are pinned
# below, for the reason the declared-wait cases above give: a bound proved only in
# the quiet direction is indistinguishable from deleting wedge detection.
# Related, and deliberately NOT closed by this: upstream #4412, #4482, #4316.

# The two endpoint verdicts that are PROOF an agent is gone, as the lane fixture
# above reaches them: `dead` is the recorded window still present in the session
# inventory with a bare shell in front of it (the husk a crashed agent leaves),
# and `missing` is an inventory that no longer carries that window at all.
gone_endpoint_env() {  # <dead|missing> -> assignments for the round below
  case "$1" in
    dead)    FM_TEST_PANE_COMMAND=bash FM_TEST_TMUX_WINDOWS=fm-wedge ;;
    missing) FM_TEST_PANE_COMMAND=bash FM_TEST_TMUX_WINDOWS=fm-someone-else ;;
  esac
}

test_gone_endpoint_reports_once_instead_of_escalating_forever() {
  local dir state fakebin out capture window key verdict round
  local failed='state: failed · source: run-step · run failed'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for verdict in dead missing; do
    dir=$(wedge_threshold_fixture "gone-endpoint-$verdict" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    gone_endpoint_env "$verdict"
    export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS

    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
      || fail "a $verdict endpoint was never reported at the wedge threshold: $(cat "$out")"
    grep -F "agent $verdict" "$out" >/dev/null \
      || fail "the $verdict report did not name the endpoint verdict: $(cat "$out")"
    grep -F 'possible wedge' "$out" >/dev/null \
      && fail "a $verdict endpoint was still reported as a possible wedge: $(cat "$out")"
    [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
      || fail "a $verdict endpoint queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "a $verdict endpoint advanced the wedge escalation count"
    ack_stopped_cycle "$state" || fail "could not acknowledge the $verdict report"

    # The defect itself: every later threshold repeated the alarm, 226 times over.
    # Each of these rounds is several thresholds, and every one must stay quiet.
    round=1
    while [ "$round" -le 3 ]; do
      : > "$out"
      wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
        || fail "a $verdict endpoint re-alarmed on later threshold $round: $(cat "$out")"
      [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
        || fail "a $verdict endpoint queued a repeat wake on round $round: $(cat "$state/.wake-queue")"
      [ ! -e "$state/.wedge-escalations-$key" ] \
        || fail "a $verdict endpoint advanced the escalation count on round $round"
      round=$((round + 1))
    done
    unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  done
  pass "a record whose endpoint is dead or missing reports itself once and is never re-escalated"
}

# The load-bearing direction. A genuinely wedged LIVE agent must escalate exactly
# as it did before, and so must every verdict short of proof: an unattributable
# foreground process (`ambiguous`) and an unreadable endpoint keep the identical
# schedule, reason and count, because neither shows the agent is gone.
test_live_and_unproven_endpoints_still_wedge_escalate() {
  local dir state fakebin out capture window key spec verdict comm inventory
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in 'alive|grok|fm-wedge' 'ambiguous|node|fm-wedge' 'unreadable||fm-wedge'; do
    verdict=${spec%%|*}; comm=${spec#*|}; inventory=${comm#*|}; comm=${comm%%|*}
    dir=$(wedge_threshold_fixture "wedge-live-$verdict" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    FM_TEST_PANE_COMMAND=$comm FM_TEST_TMUX_WINDOWS=$inventory
    export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS

    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an $verdict endpoint stopped escalating at the wedge threshold: $(cat "$out")"
    grep -F 'possible wedge, escalation 1' "$out" >/dev/null \
      || fail "an $verdict endpoint lost its wedge reason: $(cat "$out")"
    [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
      || fail "an $verdict endpoint did not advance the escalation count"
    ack_stopped_cycle "$state" || fail "could not acknowledge the $verdict escalation"

    # And it keeps escalating, with the count climbing exactly as it always did.
    : > "$out"
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an $verdict endpoint escalated only once: $(cat "$out")"
    grep -F 'possible wedge, escalation 2' "$out" >/dev/null \
      || fail "an $verdict endpoint did not keep counting: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the second $verdict escalation"
    unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  done
  pass "a live wedged agent, an unattributable one, and an unreadable endpoint escalate unchanged"
}

# --- opt-in operator guards consulted at the wedge threshold -----------------
# Upstream kunchenguid/firstmate#6919: docs/jev-guards.md says a CRITICAL guard
# verdict explains worker silence and its caller should not escalate a wedge
# while it holds, but nothing called a guard. config/wedge-evidence-guards lists
# operator guard executables the at-threshold branch consults after every other
# deferral and the dead-endpoint probe. Each case pins one direction, and the
# unconfigured case is pinned against an armed control so its zero guard calls
# cannot be a fixture that never reached the consult.

# Write one guard executable into the case. Every call appends the task,
# endpoint and argv it received to <case-dir>/guard.calls before <body> runs.
make_wedge_guard() {  # <case-dir> <name> <body> -> guard path
  local dir=$1 name=$2 body=$3 f
  mkdir -p "$dir/guards"
  f="$dir/guards/$name"
  # shellcheck disable=SC2016 # single quotes are deliberate: the guard's own variables expand when the guard runs, not here
  printf '#!/bin/sh\nprintf "%%s %%s %%s\\n" "$FM_GUARD_TASK" "$FM_GUARD_ENDPOINT" "$*" >> "%s/guard.calls"\n%s\n' \
    "$dir" "$body" > "$f"
  chmod 700 "$f"
  printf '%s\n' "$f"
}

arm_wedge_guards() {  # <case-dir> <guard-path>...
  local dir=$1
  shift
  printf '%s\n' '# operator guards' '' "$@" > "$dir/config/wedge-evidence-guards"
  chmod 600 "$dir/config/wedge-evidence-guards"
}

wedge_guard_calls() {  # <case-dir>
  if [ -e "$1/guard.calls" ]; then wc -l < "$1/guard.calls" | tr -d ' '; else echo 0; fi
}

WEDGE_GUARD_CRITICAL='printf "%s\n" "{\"name\":\"ticket\",\"status\":\"CRITICAL\",\"recommendation\":\"ticket 7 is held by a live job\"}"'

test_wedge_guards_absent_config_keeps_the_unchanged_ladder() {
  local dir state fakebin out capture window key n guard
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')

  dir=$(wedge_threshold_fixture guards-absent 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL" >/dev/null
  [ ! -e "$dir/config/wedge-evidence-guards" ] \
    || fail "the unconfigured fixture armed the guards, so it proves nothing"
  n=1
  while [ "$n" -le 3 ]; do
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an unconfigured home stopped escalating at threshold $n: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge unconfigured escalation $n"
    [ "$n" -ge 3 ] \
      || grep -E "^stale: $window \(idle [0-9]+s, possible wedge, escalation $n\)\$" "$out" >/dev/null \
      || fail "an unconfigured home changed escalation $n's reason: $(cat "$out")"
    n=$((n + 1))
  done
  grep -F 'escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)' "$out" >/dev/null \
    || fail "an unconfigured home lost the demand-deep-inspection wording: $(cat "$out")"
  grep -F 'guard' "$out" >/dev/null && fail "an unconfigured home named a guard: $(cat "$out")"
  [ "$(wedge_guard_calls "$dir")" -eq 0 ] \
    || fail "an unconfigured home ran a guard $(wedge_guard_calls "$dir") time(s)"
  [ ! -e "$state/.guard-deferrals-$key" ] || fail "an unconfigured home wrote a guard-deferral record"

  # The same fixture with only the config added must reach the guard.
  dir=$(wedge_threshold_fixture guards-armed-control 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  FM_WEDGE_GUARD_DEFER_MAX=0 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "the armed control did not escalate with a zero deferral cap: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the armed control"
  [ "$(wedge_guard_calls "$dir")" -gt 0 ] \
    || fail "the armed control ran no guard, so the zero above proves nothing"
  pass "with config/wedge-evidence-guards absent no guard runs and the ladder, timing and wording are unchanged"
}

test_wedge_guard_critical_defers_one_window_at_a_time_up_to_the_cap() {
  local dir state fakebin out capture window key guard
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture guards-critical 'working: running the remote suite' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  export FM_WEDGE_GUARD_DEFER_MAX=2

  # Two thresholds are deferred, one window each, and the third escalates
  # anyway: the guard is asked once per window, never twice in one.
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a CRITICAL guard silenced the lane past its deferral cap: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the capped escalation"
  [ "$(wedge_guard_calls "$dir")" -eq 3 ] \
    || fail "a cap of 2 asked the guard $(wedge_guard_calls "$dir") time(s) before escalating, not 3: $(cat "$dir/guard.calls")"
  grep -Fx "wedge $window --json" "$dir/guard.calls" >/dev/null \
    || fail "the guard did not receive the task, endpoint and --json: $(cat "$dir/guard.calls")"
  grep -F "possible wedge, escalation 1; guard ticket still reports CRITICAL (ticket 7 is held by a live job) after its consecutive-deferral cap, so recheck the lane)" "$out" >/dev/null \
    || fail "the capped escalation did not name the guard and its reason: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null)" = 1 ] \
    || fail "guard deferrals advanced the escalation count"
  [ ! -e "$state/.guard-deferrals-$key" ] || fail "the escalation did not end the deferral run"

  # The escalation ended the run, so a guard that stays CRITICAL still lets the
  # lane escalate once every cap+1 windows, with the count climbing as before.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a CRITICAL guard silenced the lane after its first capped escalation: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second capped escalation"
  grep -F "possible wedge, escalation 2; guard ticket still reports CRITICAL" "$out" >/dev/null \
    || fail "the second capped escalation did not keep counting: $(cat "$out")"

  # The run is a durable record, not memory: a restarted watcher resumes it.
  dir=$(wedge_threshold_fixture guards-restart 'working: running the remote suite' 0 5)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  printf '2\n' > "$state/.guard-deferrals-$key"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a restarted watcher forgot the deferral run: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the restarted escalation"
  [ "$(wedge_guard_calls "$dir")" -eq 1 ] \
    || fail "a restarted watcher deferred again past a recorded full run: $(cat "$dir/guard.calls")"
  unset FM_WEDGE_GUARD_DEFER_MAX
  pass "a CRITICAL guard defers one window at a time, the cap escalates naming the guard, and the run survives a restart"
}

test_wedge_guard_failures_fail_open() {
  local dir state fakebin out capture window key spec label body guard
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  for spec in \
    'timeout|sleep 10' \
    'nonzero|printf "%s\n" "{\"status\":\"CRITICAL\",\"recommendation\":\"r\"}"; exit 3' \
    'malformed|printf "%s\n" "CRITICAL ticket 7"' \
    'two-documents|printf "%s\n" "{\"status\":\"CRITICAL\",\"recommendation\":\"r\"}" "{\"status\":\"OK\",\"recommendation\":\"r\"}"' \
    'empty-reason|printf "%s\n" "{\"status\":\"CRITICAL\",\"recommendation\":\" \"}"' \
    'unknown|printf "%s\n" "{\"status\":\"UNKNOWN\",\"recommendation\":\"cannot read the queue\"}"' \
    'warning|printf "%s\n" "{\"status\":\"WARNING\",\"recommendation\":\"queue is slow\"}"'; do
    label=${spec%%|*}; body=${spec#*|}
    dir=$(wedge_threshold_fixture "guards-fail-open-$label" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    guard=$(make_wedge_guard "$dir" "$label" "$body")
    arm_wedge_guards "$dir" "$guard"
    FM_WEDGE_GUARD_TIMEOUT_SECS=1 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "a $label guard took the ladder away: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the $label escalation"
    grep -E "^stale: $window \(idle [0-9]+s, possible wedge, escalation 1\)$" "$out" >/dev/null \
      || fail "a $label guard changed the escalation: $(cat "$out")"
    [ "$(wedge_guard_calls "$dir")" -ge 1 ] || fail "the $label guard was never asked, so this proves nothing"
    [ ! -e "$state/.guard-deferrals-$key" ] || fail "a $label guard recorded a deferral"
  done

  # Untrusted configuration is never executed: a group-writable list, and a
  # listed guard writable by others, each keep the unchanged escalation.
  for label in config guard; do
    dir=$(wedge_threshold_fixture "guards-untrusted-$label" 'working: still compiling' 0)
    state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
    guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
    arm_wedge_guards "$dir" "$guard"
    case "$label" in
      config) chmod 660 "$dir/config/wedge-evidence-guards" ;;
      guard) chmod 777 "$guard" ;;
    esac
    wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
      || fail "an untrusted $label took the ladder away: $(cat "$out")"
    ack_stopped_cycle "$state" || fail "could not acknowledge the untrusted-$label escalation"
    grep -F 'possible wedge, escalation 1)' "$out" >/dev/null \
      || fail "an untrusted $label changed the escalation: $(cat "$out")"
    [ "$(wedge_guard_calls "$dir")" -eq 0 ] || fail "an untrusted $label was executed"
  done
  pass "a guard that times out, fails, answers malformed, UNKNOWN or WARNING, or is untrusted leaves the ladder unchanged"
}

test_wedge_guard_never_defers_a_gone_endpoint() {
  local dir state fakebin out capture window guard
  local failed='state: failed · source: run-step · run failed'
  window="test:fm-wedge"
  dir=$(wedge_threshold_fixture guards-gone 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
  guard=$(make_wedge_guard "$dir" ticket "$WEDGE_GUARD_CRITICAL")
  arm_wedge_guards "$dir" "$guard"
  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a CRITICAL guard hid a gone endpoint: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the gone report"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  grep -F 'agent missing' "$out" >/dev/null || fail "the gone endpoint was not reported as gone: $(cat "$out")"
  [ "$(wedge_guard_calls "$dir")" -eq 0 ] || fail "a guard was asked about a gone endpoint"
  pass "a gone endpoint is reported before any guard is asked, so a guard never defers it"
}

# Reporting once must not mean reporting once forever: a replacement launched into
# the same window has to get the full alarm back, and its own later death has to be
# reported again rather than silenced by the record of the first one.
test_gone_report_rearms_when_the_endpoint_comes_back() {
  local dir state fakebin out capture window key
  local failed='state: failed · source: run-step · run failed'
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture gone-rearm 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"

  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "the gone endpoint was never reported: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] || fail "the once-only report left no record of itself"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first gone report"

  # A replacement is launched into the same window and then wedges for real.
  FM_TEST_PANE_COMMAND=grok FM_TEST_TMUX_WINDOWS=fm-wedge
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" exit \
    || fail "a replacement agent's wedge was swallowed by the earlier gone report: $(cat "$out")"
  grep -F 'possible wedge, escalation' "$out" >/dev/null \
    || fail "a replacement agent did not escalate as a wedge: $(cat "$out")"
  [ ! -e "$state/.dead-reported-$key" ] \
    || fail "the once-only record survived an endpoint that reads live again"
  ack_stopped_cycle "$state" || fail "could not acknowledge the replacement's wedge escalation"

  # And when the replacement dies too, that death is reported in full.
  gone_endpoint_env dead
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a second death in the same window was never reported: $(cat "$out")"
  grep -F 'agent dead' "$out" >/dev/null \
    || fail "a second death was not reported as a gone endpoint: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second gone report"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass "the once-only gone report re-arms when the endpoint comes back, and reports a later death again"
}

# The swallow the once-marker must be bound against: death #1 is reported, then a
# replacement launches into the same window - churning the pane hash, which
# resets the stale suppressor, wedge timer and escalation count while NO reset
# site touches the once-marker - and then the replacement itself dies and the
# pane settles static at ITS hash. The relaunch round ends before any threshold,
# so no backend probe ever read the replacement alive; no incarnation token is
# armed for this fixture, so the marker's pane-hash fallback is all that can tell
# this death apart from the one already reported, and the second death must
# report in full, while later thresholds on the SAME dead pane stay
# silent and never advance the escalation count.
test_second_death_after_a_same_window_relaunch_reports_in_full() {
  local dir state fakebin out capture window key
  local failed='state: failed · source: run-step · run failed'
  local working='state: working · source: run-step · ci running'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture gone-relaunch-swallow 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # Death #1: the endpoint is gone and reported once, in full.
  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "the first death was never reported: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the first death report did not name the endpoint verdict: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] || fail "the first death left no once-record"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first death report"

  # A replacement launches: the pane churns and the bookkeeping resets, but the
  # round ends before the fresh timer could reach a threshold, so no probe runs
  # and the once-record survives the churn untouched.
  FM_TEST_PANE_COMMAND=grok FM_TEST_TMUX_WINDOWS=fm-wedge
  printf '%s\n' 'waiting on the build queue' > "$capture"
  : > "$out"
  FM_TEST_STALE_ESCALATE=999 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$working" absorb \
    || fail "a replacement launch churned the pane without absorbing: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null \
    && fail "the relaunch round escalated before its fresh window elapsed: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] \
    || fail "the relaunch churn dropped the first death's once-record"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the relaunch churn left a wedge escalation count behind"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "the relaunch churn queued a wake: $(cat "$state/.wake-queue")"

  # The replacement dies too, without any intervening probe reading it alive:
  # the second death must still produce its own detailed report naming the
  # verdict, and must not be absorbed by the first death's record.
  gone_endpoint_env missing
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a second death after a same-window relaunch was never reported: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the second death was not reported as a gone endpoint: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the second death queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the second death advanced the wedge escalation count"
  ack_stopped_cycle "$state" || fail "could not acknowledge the second death report"

  # And later thresholds on the same unchanged dead pane stay silent: the
  # bound still holds once the replacement's own death is the reported one.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
    || fail "an unchanged dead pane re-alarmed after the second report: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "an unchanged dead pane queued a repeat wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an unchanged dead pane advanced the escalation count"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass "a second death after a same-window relaunch reports in full without a live probe, and an unchanged dead pane stays silent"
}

# The collision the pane-hash discriminator cannot see: a successor whose dead
# display is BYTE-IDENTICAL to the death already reported - the common case,
# since a dead husk display is deterministic (a bare shell in the same cwd,
# restored empty scrollback). The successor dies without any threshold probe
# reading it alive, so the pane never churns and no hash change can announce the
# replacement; only the busy incarnation, re-armed through the real writer
# (bin/fm-busy-event.sh arm, exactly as a relaunch replaces the previous one),
# can tell this death from the reported one. It must report in full, while later
# thresholds on the same dead pane under the SAME incarnation still absorb and
# never advance the escalation count.
test_identical_dead_display_of_a_successor_still_reports() {
  local dir state fakebin out capture window key
  local failed='state: failed · source: run-step · run failed'
  window="test:fm-wedge"; key=$(printf '%s' "$window" | tr ':/.' '___')
  dir=$(wedge_threshold_fixture identical-dead-display 'working: still compiling' 0)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"

  # The lane's busy contract is armed at spawn, so the first death's once-record
  # is keyed on that incarnation.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" wedge >/dev/null \
    || fail "could not arm the lane's busy incarnation"

  # Death #1: the endpoint is gone and reported once, in full.
  gone_endpoint_env missing; export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "the first death was never reported: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the first death report did not name the endpoint verdict: $(cat "$out")"
  [ -s "$state/.dead-reported-$key" ] || fail "the first death left no once-record"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the first death queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first death report"

  # A successor occupies the lane: the relaunch re-arms the busy incarnation
  # through the real writer, and the successor stays quiet under the threshold
  # for a round, so no probe reads it alive and the pane never churns - the
  # display captured here and in the death rounds is byte-identical throughout.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" wedge >/dev/null \
    || fail "could not re-arm the successor's busy incarnation"
  : > "$out"
  FM_TEST_STALE_ESCALATE=999 wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
    || fail "the successor's quiet round was never absorbed: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "the successor's quiet round queued a wake: $(cat "$state/.wake-queue")"

  # The successor dies into the same byte-identical display. A pane-hash marker
  # absorbs this death silently; the incarnation half must report it in full.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" exit \
    || fail "a byte-identical dead display absorbed the successor's death: $(cat "$out")"
  grep -F 'agent missing' "$out" >/dev/null \
    || fail "the successor's death was not reported as a gone endpoint: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 1 ] \
    || fail "the successor's death queued $(wedge_stale_wakes "$state" "$window") wakes instead of one"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the successor's death advanced the wedge escalation count"
  ack_stopped_cycle "$state" || fail "could not acknowledge the successor's death report"

  # Later thresholds on the same unchanged dead pane under the SAME incarnation
  # stay silent: the once-only bound still holds within one incarnation.
  : > "$out"
  wedge_threshold_round "$state" "$fakebin" "$out" "$capture" "$window" "$failed" absorb \
    || fail "an unchanged dead pane re-alarmed under the same incarnation: $(cat "$out")"
  [ "$(wedge_stale_wakes "$state" "$window")" -eq 0 ] \
    || fail "an unchanged dead pane queued a repeat wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "an unchanged dead pane advanced the escalation count"
  unset FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
  pass "a successor's byte-identical dead display reports in full, and the same incarnation still absorbs"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge wedge escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# --- busy pane duration bound: a completed-turn age gate on top of busy -----
# 2026-07 hibit-agent-focus-nonsteal-r1 incident: a busy pane (herdr "working"
# and/or the harness's rendered busy footer) is unconditional, unbounded proof
# of liveness in every existing classifier, so a genuinely hung foreground tool
# call behind a busy signature ran undetected for 25h. BUSY_TURN_MAX_SECS bounds
# how long a busy pane may run with no completed turn (state/<id>.turn-ended, or
# the task's spawn record before any turn completes); past the bound, panes
# without a declared external wait or verified captain-held transfer take the
# SAME wedge_timer_check already used for a provably-working non-busy stale.
# Escalation reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker - never an
# automatic interrupt or restart.

test_busy_pane_below_turn_age_bound_is_absorbed() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-below-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-fresh"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-fresh.meta"
  record_pi_busy "$state" busy-fresh
  printf 'working: setup complete\n' > "$state/busy-fresh.status"
  sig=$(seen_sig "$state/busy-fresh.status"); printf '%s' "$sig" > "$state/.seen-busy-fresh_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch "$state/busy-fresh.turn-ended"
  prime_turnend_seen "$state/busy-fresh.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a busy pane below the turn-age bound was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a busy pane below the turn-age bound printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane below the turn-age bound started a wedge timer"
  reap "$pid"
  pass "a busy worker below the turn-age bound remains working with no escalation"
}

test_busy_pane_stable_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-stable-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-stable"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-stable.meta"
  record_pi_busy "$state" busy-stable
  printf 'working: setup complete\n' > "$state/busy-stable.status"
  sig=$(seen_sig "$state/busy-stable.status"); printf '%s' "$sig" > "$state/.seen-busy-stable_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself.
  touch -t 200001010000 "$state/busy-stable.meta"

  # Phase A: past the bound, the stable-hash busy pane is absorbed but starts
  # the wedge timer (mirrors the existing provably-working-stale Phase A/B).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a stable-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a stable-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional stable-hash phase-A stop"

  # Phase B: backdate the wedge timer past the threshold; the next poll escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stable-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation did not flag a possible wedge"
  pass "a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound"
}

# Regression fixture for the incident's actual masking condition: Pi's rendered
# elapsed-time footer changes every poll, so the pane hash never repeats and the
# watcher always takes the "new hash" branch, never the stable-hash one above.
test_busy_pane_changing_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case busy-changing-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-ticking"
  printf 'Working... (3600.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-ticking.meta"
  record_pi_busy "$state" busy-ticking
  printf 'working: setup complete\n' > "$state/busy-ticking.status"
  sig=$(seen_sig "$state/busy-ticking.status"); printf '%s' "$sig" > "$state/.seen-busy-ticking_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-ticking.meta"
  # No pre-seeded .hash-<key>: with a real ticking elapsed footer, every poll
  # lands here (h != prev) - the reproduction's actual masking condition.

  # Phase A: first sight past the bound absorbs and starts the wedge timer,
  # without ever needing the "genuinely stale" hash-match path.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a changing-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a changing-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional changing-hash phase-A stop"

  # Phase B: another tick (still a fresh, never-before-seen hash) plus a
  # backdated wedge timer escalates exactly as the stable-hash case does.
  printf 'Working... (3601.2s)' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a changing-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not flag a possible wedge"
  pass "a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound"
}

test_busy_pane_turn_end_touch_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-turn-end-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker's most recent turn just completed: touching turn-ended resets age.
  touch "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a freshly completed turn on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a freshly completed turn on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a freshly completed turn did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a freshly completed turn did not clear the escalation counter"
  reap "$pid"
  pass "touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation"
}

test_busy_pane_native_progress_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-native-progress-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker has progressed without completing its long native turn.
  touch "$state/busy-reset.progress"
  touch -t 200001010000 "$state/busy-reset.meta"
  touch -t 200001010000 "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a fresh native activity on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a fresh native activity on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a fresh native activity did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a fresh native activity did not clear the escalation counter"
  reap "$pid"
  pass "native progress resets busy age without a completed turn or notification"
}

test_busy_pane_claude_tool_progress_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-claude-progress-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-claude-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=claude\n' "$window" > "$state/busy-claude.meta"
  printf 'working: setup complete\n' > "$state/busy-claude.status"
  sig=$(seen_sig "$state/busy-claude.status"); printf '%s' "$sig" > "$state/.seen-busy-claude_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The Claude worker's last completed turn is ancient, but its PostToolUse
  # hook just refreshed the progress marker through the real producer.
  touch -t 200001010000 "$state/busy-claude.meta"
  touch -t 200001010000 "$state/busy-claude.turn-ended"
  prime_turnend_seen "$state/busy-claude.turn-ended"
  record_claude_busy "$state" busy-claude
  [ -f "$state/busy-claude.progress" ] || fail "fixture: the progress producer did not write the marker"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a Claude worker with fresh tool progress was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a Claude worker with fresh tool progress printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "fresh Claude tool progress did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "fresh Claude tool progress did not clear the escalation counter"
  reap "$pid"
  pass "a Claude worker's PostToolUse progress resets busy age exactly like Pi native progress"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case busy-turn-age-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-demand-inspect"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting past the turn-age bound absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming round for busy turn-age escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional busy-wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "busy turn-age escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "busy turn-age round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "busy turn-age round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "busy turn-age round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge busy turn-age escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "busy turn-age escalation counter did not persist across consecutive rounds"
  pass "repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold"
}

# --- declared pause + busy pane: the busy-turn bound must honor the declaration
# A single foreground call can keep a declared external wait semantically busy
# past the completed-turn bound, bypassing the ordinary stale-pause path.
# This fixture pins all three halves of the contract: the declared pause is
# absorbed instead of wedged (A), it is still rechecked on the long
# PAUSE_RESURFACE_SECS cadence so a forgotten wait cannot rot invisibly (B), and
# lifting the declaration on the SAME busy over-age pane restores the wedge
# escalation, proving the discriminator is the worker's own declaration and not a
# blanket silencing of the escalator (C).
test_busy_declared_pause_is_rechecked_not_wedge_escalated() {
  local dir state fakebin out capture_file window key sig pid statusf back
  dir=$(make_case busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-review-scout"
  statusf="$state/review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/review-scout.meta"
  record_pi_busy "$state" review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # No completed turn for hours (the single blocking poll call): age the spawn
  # record itself, exactly as the never-completed-a-turn fixtures above do.
  touch -t 200001010000 "$state/review-scout.meta"
  # No pre-seeded .hash-<key>: a live harness footer ticks, so every poll lands
  # on the changed-hash branch - the review scout's real masking condition.

  # Phase A: past the bound, with the wedge threshold set as low as it goes, the
  # declared pause is absorbed on the long cadence and never starts a wedge.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a declared pause on a busy review pane was escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a declared pause on a busy review pane printed a wake reason: $(cat "$out")"
  [ -e "$state/.paused-$key" ] || fail "the busy-turn bound did not apply the declared-pause cadence"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared pause on a busy pane started the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a declared pause on a busy pane incremented the escalation counter"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional declared-pause phase-A stop"

  # Phase B: age the pause past the (now normal) long cadence and let the pane
  # settle on one stable hash, so the still-busy pane takes the repeat-hash
  # branch whose pause bookkeeping the bound must not wipe. It re-surfaces once
  # as a recheck, never as a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a declared pause past the long cadence was never rechecked"; }
  grep -F "awaiting external" "$out" >/dev/null || fail "the recheck was not labeled a declared-pause recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause on a busy pane was mislabeled a possible wedge: $(cat "$out")"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the declared-pause re-surface throttle was cleared by the busy-turn bound"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared-pause recheck used the wedge timer"
  ack_stopped_cycle "$state" || fail "could not acknowledge the declared-pause recheck"

  # Phase C: the pause is lifted on the SAME busy, over-age pane. Nothing else
  # changes, so a still-absorbed pane here would mean the bound was silenced
  # rather than taught the declaration. It must wedge-escalate exactly as before.
  printf 'working: review closed, resuming the sweep\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a lifted pause escalated before the wedge threshold: $(cat "$out")"; }
  reap "$pid"
  [ -s "$state/.stale-since-$key" ] || fail "a lifted pause did not restore the busy-turn wedge timer"
  [ ! -e "$state/.paused-$key" ] || fail "a lifted pause left stale declared-pause bookkeeping behind"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional lifted-pause priming stop"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a lifted pause on an over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the restored busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "a busy pane under a declared pause is rechecked on the long cadence, and lifting the pause restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE: the bound must hand off, not decorate
# Away mode is daemon-owned: the watcher reverts to one-shot and lets the daemon
# classify. The busy-turn bound used to be the one stale path that ignored that,
# running the wedge timer under afk and handing the daemon a wake already decorated
# as a possible wedge. That decoration outranks the daemon's own pause verdict, so a
# crew that declared the wait itself was wedge-escalated once per
# FM_STALE_ESCALATE_SECS for as long as the wait lasted, with the escalation count
# climbing into demand-deep-inspection on a pane nobody needed to inspect.
# Phase A pins the handoff: the plain window identity, no wedge timer, no escalation
# counter, and no normal-mode pause bookkeeping (the daemon owns that in away mode).
# Phase B re-arms on the same unchanged pane and pins the one-shot: a second wake
# here is what the climbing ladder looked like. Phase C drives the discriminator
# apart on the SAME afk, busy, over-age pane - lifting the declaration restores the
# wedge escalation, so this is the worker's declaration being honored rather than
# away mode silencing the escalator.
test_afk_busy_declared_pause_hands_off_plain_stale() {
  local dir state fakebin out capture_file window key sig pid statusf
  dir=$(make_case afk-busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-afk-review-scout"
  statusf="$state/afk-review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/afk-review-scout.meta"
  record_pi_busy "$state" afk-review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/afk-review-scout.meta"
  date '+%s' > "$state/.afk"

  # Phase A: past the bound, with the wedge threshold as low as it goes, the
  # declaration is handed to the daemon undecorated instead of being wedge-timed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed the declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff started the wedge timer on a declared pause"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff incremented the wedge escalation count on a declared pause"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking instead of leaving it to the daemon"
  ack_stopped_cycle "$state" || fail "could not acknowledge the away-mode declared-pause handoff"

  # Phase B: re-arm on the same unchanged pane. The bound has already handed this
  # stale hash off, so it must stay silent rather than re-waking the daemon - a
  # second wake here is the escalation ladder the wedge timer used to climb.
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "the away-mode bound re-woke on an already-handed-off declared pause: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the away-mode bound re-surfaced an already-handed-off declared pause: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "re-arming on an unchanged declared pause started a wedge escalation ladder"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional away-mode re-arm stop"

  # Phase C: lift the declaration on the SAME afk, busy, over-age pane. Nothing else
  # changes, so a wedge escalation here proves the declaration was the discriminator.
  printf 'working: resumed the review write-up\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "a lifted pause on an away-mode over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the restored away-mode busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "away mode hands a busy declared pause to the daemon as a plain stale, and lifting the declaration restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE + a TICKING footer: one wake per declaration
# The static-pane case above cannot tell a hash-keyed one-shot from a
# declaration-keyed one, because its capture never changes between polls. The
# incident pane's harness footer ticks on every capture, so a one-shot keyed on the
# pane hash re-fires on every poll, and the daemon, which relaunches the watcher
# after each handled wake, is woken in a loop for the whole declared wait. This
# fixture's fake tmux renders a fresh footer on EVERY capture-pane and asserts that
# divergence outright on every re-arm (.hash-<key> moves, .count-<key> never
# climbs), so the one-wake assertion across five silent re-arms cannot pass
# vacuously on a pane that happened to sit still. Round 1 also starts from an
# undeclared wedge timer and escalation count, which the handoff must clear the
# way the normal-mode absorber does, so lifting the declaration later starts the
# wedge path from a fresh timer rather than resuming a stale count.
test_afk_busy_declared_pause_ticking_pane_hands_off_once() {
  local dir state fakebin out drain_out window key sig pid statusf ticks round prev_hash cur_hash prev_ticks
  dir=$(make_case afk-busy-declared-pause-ticking); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; window="test:fm-afk-ticking-scout"
  statusf="$state/afk-ticking-scout.status"; ticks="$dir/ticks"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
    exit 0 ;;
  capture-pane)
    n=$(( $(cat "$FM_FAKE_TMUX_TICKS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FM_FAKE_TMUX_TICKS"
    printf 'Working... (%d.%ds) lavish-axi poll' "$(( 7200 + n ))" "$(( n % 10 ))"
    exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
    esac ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf 'window=%s\nkind=scout\nharness=pi\n' "$window" > "$state/afk-ticking-scout.meta"
  record_pi_busy "$state" afk-ticking-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-ticking-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/afk-ticking-scout.meta"
  date '+%s' > "$state/.afk"
  # An undeclared busy phase already ran the wedge timer and escalated twice
  # before the crew declared the wait.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  date +%s > "$state/.writing-since-$key"

  # Round 1: the declaration is handed off once, undecorated, and the undeclared
  # phase's wedge bookkeeping is cleared with it.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_TICKS="$ticks" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed a ticking declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity for a ticking pane: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a ticking declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's wedge timer in place"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's escalation count in place"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's write-deferral chain in place"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking on a ticking pane"
  ack_stopped_cycle "$state" || fail "could not acknowledge the ticking declared-pause handoff"

  # Rounds 2-6: five consecutive re-arms on the same standing declaration. Every
  # capture renders a new footer, so every poll lands on the changed-hash branch -
  # the exact shape a hash-keyed one-shot re-fires on. Each round proves the pane
  # really moved before it asserts silence, so the case cannot go vacuous.
  round=2
  while [ "$round" -le 6 ]; do
    prev_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    prev_ticks=$(cat "$ticks" 2>/dev/null || echo 0)
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_TICKS="$ticks" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
      FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
      FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "re-arm $round on a ticking declared pause re-woke the daemon: $(cat "$out")"; }
    reap "$pid"
    cur_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    [ "$(cat "$ticks" 2>/dev/null || echo 0)" -gt "$prev_ticks" ] \
      || fail "re-arm $round never captured the pane, so its silence proves nothing"
    [ -n "$cur_hash" ] && [ "$cur_hash" != "$prev_hash" ] \
      || fail "re-arm $round saw the same pane hash as the round before, so it cannot tell a hash-keyed one-shot from a declaration-keyed one"
    [ "$(cat "$state/.count-$key" 2>/dev/null || echo missing)" = 0 ] \
      || fail "re-arm $round settled on a stable hash instead of ticking on every poll"
    [ ! -s "$out" ] || fail "re-arm $round re-surfaced a standing declared pause on a ticking pane: $(cat "$out")"
    [ ! -e "$state/.stale-since-$key" ] \
      || fail "re-arm $round started the wedge timer on a standing declared pause"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "re-arm $round climbed the wedge escalation ladder on a standing declared pause"
    ack_stopped_cycle "$state" || fail "could not acknowledge the intentional re-arm $round stop"
    round=$((round + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  grep "$(printf '\tstale\t')" "$drain_out" >/dev/null \
    && fail "the silent re-arms still queued a stale row for the standing declaration: $(cat "$drain_out")"
  pass "away mode wakes the daemon once per declaration for a busy pane whose footer ticks on every capture"
}

# Behavioral proof that the production default (no FM_BUSY_TURN_MAX_SECS override
# anywhere in this env) is 3600s: a completed turn 5 minutes old must not start a
# wedge timer, while one 66 minutes old must - bracketing the default around 3600
# without waiting a literal hour.
test_busy_pane_default_turn_age_bound_is_3600s() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-default-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-default"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-default.meta"
  record_pi_busy "$state" busy-default
  printf 'working: setup complete\n' > "$state/busy-default.status"
  sig=$(seen_sig "$state/busy-default.status"); printf '%s' "$sig" > "$state/.seen-busy-default_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  set_mtime $(( $(date +%s) - 300 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 5-minute-old completed turn tripped the default busy-turn-age bound: $(cat "$out")"
  fi
  [ ! -e "$state/.stale-since-$key" ] || fail "a 5-minute-old completed turn started a wedge timer under the default bound"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional five-minute-bound stop"

  set_mtime $(( $(date +%s) - 4000 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 66-minute-old completed turn escalated before the wedge threshold under the default bound: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a 66-minute-old completed turn did not start a wedge timer under the default bound (default is not 3600s)"
  reap "$pid"
  pass "the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional missing-timer repair stop"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- quiet pane, worktree still being written: deferred, never wedge-escalated -
# The live 2026-08-14 case: one crew produced eight consecutive possible-wedge
# escalations in an afternoon, three of them demanding deep inspection, while it
# was demonstrably writing source, then tests, then documentation. The detector's
# two inputs (pane quietness, run step) cannot see that, so the pane looks frozen.
# Both halves of the contract are asserted on the SAME fixture, because the whole
# point is that only the worktree evidence differs: writing defers, silent
# escalates on the unchanged schedule.
# Every wait below is the file's standard one (wait_poll_cycle for an absorbing
# watcher, a 100-tick wait_for_exit for an escalating one), because the poll these
# tests assert on is the ONE poll that spawns the bounded worktree walk: on a
# loaded runner it outlives a fixed liveness budget, and a round reaped before it
# finished reports a lost deferral instead of the deferral under test.
test_wedge_escalation_deferred_while_worktree_is_written() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-worktree-writes); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-writing"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/writing.meta"
  printf 'working: implementing\n' > "$state/writing.status"
  sig=$(seen_sig "$state/writing.status"); printf '%s' "$sig" > "$state/.seen-writing_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already-classified hash with an idle window that opened 500s ago, so the very
  # first stale poll lands straight on the at-threshold wedge branch (this repeat
  # path never re-reads crew state, so the worktree evidence is the only input
  # that can change the outcome).
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"

  # Phase A: the crew wrote a file after the idle window opened. Deferred.
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher wedge-escalated a quiet pane whose worktree was being written: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a written-worktree deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a written-worktree deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the write-deferral chain marker was not recorded"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a deferral advanced the wedge escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "a deferral did not restart the idle timer, so the next window cannot re-probe"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: same fixture, same quiet pane, but nothing written during this idle
  # window (the crew really is stalled). The unchanged schedule must still fire.
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/main.c"
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stalled crew that wrote nothing did not wedge-escalate on the existing schedule"
  grep -F "stale: $window" "$out" >/dev/null || fail "the stalled-crew escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the stalled-crew escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the stalled-crew escalation was not counted"
  [ ! -e "$state/.stale-since-$key" ] || fail "the idle timer was not cleared after a real escalation"
  [ ! -e "$state/.writing-since-$key" ] || fail "the write-deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the stalled-crew escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the stalled-crew escalation was not queued"
  pass "a quiet pane writing its own worktree is deferred, while one writing nothing still wedge-escalates on the unchanged schedule"
}

# A deferral is not silence. A worktree can churn without real progress (a
# rewritten log, a build touching the same file), so the whole deferral chain ages
# and re-surfaces once per PAUSE_RESURFACE_SECS - the same bounded cadence a
# declared pause uses - labeled as a recheck rather than a wedge.
test_write_deferral_resurfaces_on_the_bounded_cadence() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back
  dir=$(make_case wedge-worktree-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-churn"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/churn.meta"
  printf 'working: implementing\n' > "$state/churn.status"
  sig=$(seen_sig "$state/churn.status"); printf '%s' "$sig" > "$state/.seen-churn_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  # This pane has been deferring on write evidence for 500s already.
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  printf 'churn\n' > "$wt/src/main.c"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a long-running write deferral never re-surfaced on the bounded cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "the write-deferral recheck did not print a stale wake"
  grep -F "writing its worktree" "$out" >/dev/null || fail "the write-deferral recheck was not labeled as such"
  grep -F "possible wedge" "$out" >/dev/null && fail "a write-deferral recheck was mislabeled a possible wedge"
  [ -e "$state/.writing-resurfaced-$key" ] || fail "the write-deferral re-surface throttle marker was not recorded"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a write-deferral recheck advanced the wedge escalation counter"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the write-deferral recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the write-deferral recheck was not queued"
  pass "a write deferral re-surfaces once on the bounded pause cadence, so a churning worktree cannot stay invisible"
}

# The wedge detector's fourth liveness input: a process running inside the crew's
# own recorded worktree that STARTED after the idle window opened. Presence alone
# is deliberately not evidence - the harness, its shell, and any helper it keeps
# alive sit in the worktree from spawn to teardown - so the probe must ignore a
# process older than the anchor exactly as it ignores one that is gone, and
# every negative outcome must report "no evidence" so the caller keeps its
# schedule. Real processes, no stub: a sleep launched with its cwd in the tree.
test_crew_worktree_process_live_classifier() {
  local dir state anchor wt home pid
  dir=$(make_case classify-worktree-process); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; home="$dir/mate-home"
  mkdir -p "$wt/src" "$home/state"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-p\nkind=ship\nworktree=%s\n' "$wt" > "$state/p.meta"
  # Nothing running there: no evidence.
  ! crew_worktree_process_live p "$state" "$anchor" \
    || fail "an idle worktree reported process evidence"
  # A process born after the anchor with its cwd in the tree: positive evidence.
  ( cd "$wt" && exec sleep 300 ) &
  pid=$!
  sleep 1
  crew_worktree_process_live p "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "a process started in the worktree after the anchor was not reported"; }
  # The same process, with an anchor written AFTER it started, is the harness
  # sitting there since spawn: not evidence.
  sleep 1
  : > "$anchor"
  sleep 1
  ! crew_worktree_process_live p "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "a process older than the idle window was reported as evidence (presence alone would blind the detector)"; }
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  # No recorded worktree, a torn-down one, a missing anchor, and an empty id: no
  # evidence, even while the process is still alive.
  printf 'window=test:fm-q\nkind=ship\n' > "$state/q.meta"
  ! crew_worktree_process_live q "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "a task with no recorded worktree reported process evidence"; }
  printf 'window=test:fm-r\nkind=ship\nworktree=%s\n' "$dir/missing" > "$state/r.meta"
  ! crew_worktree_process_live r "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "a torn-down worktree reported process evidence"; }
  ! crew_worktree_process_live p "$state" "$state/absent-anchor" \
    || { kill "$pid" 2>/dev/null; fail "a missing anchor reported process evidence"; }
  ! crew_worktree_process_live "" "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "an empty id reported process evidence"; }
  # A secondmate's provisioned home runs its own supervision, so a process in it is
  # never crew evidence, whether the record says so or only the home marker does.
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf 'sm-proc\n' > "$home/.fm-secondmate-home"
  ( cd "$home" && exec sleep 300 ) &
  pid=$!
  sleep 1
  printf 'window=remote:sm\nkind=secondmate\nworktree=%s\n' "$home" > "$state/sm.meta"
  ! crew_worktree_process_live sm "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "a secondmate home's own process reported crew evidence"; }
  printf 'window=test:fm-sm2\nkind=ship\nworktree=%s\n' "$home" > "$state/sm2.meta"
  ! crew_worktree_process_live sm2 "$state" "$anchor" \
    || { kill "$pid" 2>/dev/null; fail "a marked firstmate home reported crew process evidence"; }
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  # Gone: no evidence again.
  sleep 1
  ! crew_worktree_process_live p "$state" "$anchor" \
    || fail "a finished process was still reported as evidence"
  pass "crew_worktree_process_live: a process born in the tree after the idle window is evidence; older, gone, unrecorded, and a mate's home are not"
}

# The probe's process listings run synchronously inside the poll that was about to
# escalate, so they must be wall-clock bounded like the write probe's walk. A ps
# that never answers in time stands in for a stalled process table; hitting the
# bound must read as NO evidence so the caller's escalation schedule is untouched.
test_worktree_process_probe_is_wall_clock_bounded() {
  local dir state anchor wt slowbin started elapsed pid
  dir=$(make_case classify-process-probe-bound); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; slowbin="$dir/slowbin"
  mkdir -p "$wt" "$slowbin"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=test:fm-slowps\nkind=ship\nworktree=%s\n' "$wt" > "$state/slowps.meta"
  ( cd "$wt" && exec sleep 300 ) &
  pid=$!
  sleep 1
  cat > "$slowbin/ps" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
  chmod +x "$slowbin/ps"
  started=$(date +%s)
  if PATH="$slowbin:$PATH" FM_WORKTREE_PROCESS_TIMEOUT=1 crew_worktree_process_live slowps "$state" "$anchor"; then
    kill "$pid" 2>/dev/null; fail "a process listing that outlived its bound was reported as evidence"
  fi
  elapsed=$(( $(date +%s) - started ))
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  [ "$elapsed" -lt 30 ] \
    || fail "the process probe waited ${elapsed}s on a stalled listing instead of honoring its bound"
  pass "the worktree process probe is wall-clock bounded and reads a hit bound as no evidence"
}

# --- quiet pane, a gate still running in the worktree: deferred, not escalated -
# The 2026-09-11 case: a Claude worker's screen sat on a "Waiting for task" monitor
# while `bin/fm-test-run.sh --changed` advanced test by test in a harness
# background shell, and it was wedge-escalated three times in a row (idle
# 247-250s) although a process sample showed the gate moving. The gate writes
# nothing into the tree and renders nothing, so the write probe cannot see it;
# the processes it keeps spawning there can be seen. Both halves on one fixture:
# a process born in the window defers, the same pane with that process gone
# escalates on the unchanged schedule.
test_wedge_escalation_deferred_while_worktree_process_runs() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back gate
  dir=$(make_case wedge-worktree-process); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-gate"; wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'Waiting for task' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/gate.meta"
  printf 'working: running the gate\n' > "$state/gate.status"
  sig=$(seen_sig "$state/gate.status"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Waiting for task")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already-classified hash with an idle window that opened 500s ago, so the very
  # first stale poll lands straight on the at-threshold wedge branch, and nothing
  # in the tree was written since (the gate leaves no file behind).
  printf 'old\n' > "$wt/src/main.c"
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/main.c"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"

  # Phase A: a gate process born in the worktree during the idle window. Deferred.
  ( cd "$wt" && exec sleep 300 ) &
  gate=$!
  sleep 1
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; kill "$gate" 2>/dev/null; fail "watcher wedge-escalated a quiet pane whose worktree held a live gate process: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; kill "$gate" 2>/dev/null; fail "a live-process deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; kill "$gate" 2>/dev/null; fail "a live-process deferral enqueued a wake"; }
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; kill "$gate" 2>/dev/null; fail "the deferral chain marker was not recorded for process evidence"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; kill "$gate" 2>/dev/null; fail "a deferral advanced the wedge escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; kill "$gate" 2>/dev/null; fail "a deferral did not restart the idle timer, so the next window cannot re-probe"; }
  grep -F "worktree process since the idle window opened" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; kill "$gate" 2>/dev/null; fail "the deferral was not attributed to process evidence in the triage log"; }
  reap "$pid"
  kill "$gate" 2>/dev/null; wait "$gate" 2>/dev/null || true
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: same quiet pane, same tree, the gate gone and nothing written: no
  # proof of either kind, so the unchanged schedule must still fire.
  sleep 1
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stalled crew with no process and no writes did not wedge-escalate on the existing schedule"
  grep -F "stale: $window" "$out" >/dev/null || fail "the stalled-crew escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "the stalled-crew escalation did not flag a possible wedge"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "the stalled-crew escalation was not counted"
  [ ! -e "$state/.writing-since-$key" ] || fail "the deferral chain outlived a real escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the stalled-crew escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the stalled-crew escalation was not queued"
  pass "a quiet pane whose worktree holds a gate process born in the idle window is deferred, while one with neither proof still wedge-escalates"
}

# A process deferral is not silence either: it rides the same .writing-since-<key>
# chain as the write deferral, so a tree whose process churn never amounts to
# progress still re-surfaces once per PAUSE_RESURFACE_SECS, labeled as a recheck
# that names the process evidence rather than a wedge.
test_process_deferral_resurfaces_on_the_bounded_cadence() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid wt back gate
  dir=$(make_case wedge-process-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-gate-churn"; wt="$dir/wt"
  mkdir -p "$wt"
  printf 'Waiting for task' > "$capture_file"
  printf 'window=%s\nkind=ship\nworktree=%s\n' "$window" "$wt" > "$state/gatechurn.meta"
  printf 'working: running the gate\n' > "$state/gatechurn.status"
  sig=$(seen_sig "$state/gatechurn.status"); printf '%s' "$sig" > "$state/.seen-gatechurn_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Waiting for task")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$state/.writing-since-$key"
  set_mtime "$back" "$state/.writing-since-$key"
  ( cd "$wt" && exec sleep 300 ) &
  gate=$!
  sleep 1
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { kill "$gate" 2>/dev/null; fail "a long-running process deferral never re-surfaced on the bounded cadence"; }
  kill "$gate" 2>/dev/null; wait "$gate" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null || fail "the process-deferral recheck did not print a stale wake"
  grep -F "running a process in its worktree" "$out" >/dev/null || fail "the process-deferral recheck was not labeled as such"
  grep -F "possible wedge" "$out" >/dev/null && fail "a process-deferral recheck was mislabeled a possible wedge"
  [ -e "$state/.writing-resurfaced-$key" ] || fail "the deferral re-surface throttle marker was not recorded"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a process-deferral recheck advanced the wedge escalation counter"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-deferral recheck failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "the process-deferral recheck was not queued"
  pass "a process deferral re-surfaces once on the bounded pause cadence, so a churning gate cannot stay invisible"
}

# The recorded Claude background-task exit picker. The footer is the last
# non-blank row, which is what fm_composer_blocking_dialog requires.
write_exit_picker() {  # <file>
  printf '%s\n' \
    'Background work is running' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '❯ 1. Exit and stop tasks' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel' > "$1"
}

# The same words quoted above a normal composer. That is not a live picker.
write_quoted_exit_picker() {  # <file>
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel' \
    '╭──────────────╮' \
    '│ > next steer │' \
    '╰──────────────╯' > "$1"
}

prime_picker_window() {  # <state> <id> <window> <kind> <capture> <status-line>
  local state=$1 id=$2 window=$3 kind=$4 capture=$5 status_line=$6 key statusf
  statusf="$state/$id.status"
  printf 'window=%s\nkind=%s\nbackend=tmux\n' "$window" "$kind" > "$state/$id.meta"
  printf '%s\n' "$status_line" > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-${id}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$key"
}

test_exit_picker_stale_names_the_dialog() {
  local dir state fakebin out capture_file window key pid count_file
  dir=$(make_case exit-picker-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; count_file="$dir/captures"
  window="test:fm-picker"
  write_exit_picker "$capture_file"
  key=$(prime_picker_window "$state" picker "$window" ship "$capture_file" 'working: parked between turns')
  printf '0\n' > "$count_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$count_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a pane parked on the exit picker: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "the picker wake was not a stale wake: $(cat "$out")"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$out" >/dev/null \
    || fail "the picker wake did not name the dialog: $(cat "$out")"
  grep -F 'possible wedge' "$out" >/dev/null && fail "the first picker stale was labeled a wedge: $(cat "$out")"
  [ "$(cat "$count_file")" -eq 1 ] || fail "the picker poll captured the pane $(cat "$count_file") times"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text "$(cat "$capture_file")")" ] \
    || fail "the picker stale did not record the pane hash"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the exit picker is a named stale, from the one capture the poll already takes"
}

test_exit_picker_wedge_keeps_climbing() {
  local dir state fakebin out capture_file window key pid n
  dir=$(make_case exit-picker-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-picker-wedge"
  write_exit_picker "$capture_file"
  key=$(prime_picker_window "$state" picker "$window" ship "$capture_file" 'working: parked between turns')
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a working pane on the picker exited instead of keeping the wedge timer: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a working pane on the picker woke before the wedge timer: $(cat "$out")"
  [ -s "$state/.stale-since-$key" ] || fail "the picker did not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the picker absorb"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first picker wedge did not escalate: $(cat "$out")"
  grep -F 'possible wedge, escalation 1' "$out" >/dev/null || fail "the first picker wedge lost its count: $(cat "$out")"
  grep -F 'blocked-on-prompt: Claude background-task exit picker' "$out" >/dev/null \
    || fail "the first picker wedge dropped the dialog name: $(cat "$out")"
  grep -F 'demand-deep-inspection' "$out" >/dev/null && fail "escalation 1 demanded inspection: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge picker escalation 1"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 \
    FM_WEDGE_DEMAND_INSPECT_COUNT=3 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the third picker wedge did not escalate: $(cat "$out")"
  grep -F 'possible wedge, escalation 3' "$out" >/dev/null || fail "the ladder did not reach escalation 3: $(cat "$out")"
  grep -F 'demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone, blocked-on-prompt: Claude background-task exit picker' \
    "$out" >/dev/null || fail "the dialog name was not after demand-deep-inspection: $(cat "$out")"
  n=$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)
  [ "$n" -eq 3 ] || fail "the escalation count was $n, not 3"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the exit picker keeps the wedge ladder, and the name follows demand-deep-inspection"
}

test_quoted_exit_picker_stays_ordinary_stale() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case quoted-exit-picker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quoted"
  write_quoted_exit_picker "$capture_file"
  prime_picker_window "$state" quoted "$window" ship "$capture_file" 'working: parked between turns' >/dev/null
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a quoted picker did not take the ordinary stale path: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a quoted picker was not an ordinary stale: $(cat "$out")"
  grep -F 'blocked-on-prompt' "$out" >/dev/null && fail "a quoted picker was named as a dialog: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "picker text quoted above a composer stays an ordinary stale"
}

test_secondmate_exit_picker_stays_quiet() {
  local dir state fakebin out capture_file window pid count_file
  dir=$(make_case secondmate-exit-picker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; count_file="$dir/captures"
  window="test:fm-picker-mate"
  write_exit_picker "$capture_file"
  prime_picker_window "$state" mate "$window" secondmate "$capture_file" 'working: the parent supervises this secondmate' >/dev/null
  printf '0\n' > "$count_file"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$count_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a second mate on the exit picker woke: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "a second mate on the exit picker printed a wake: $(cat "$out")"; }
  [ "$(cat "$count_file")" -eq 0 ] \
    || { reap "$pid"; fail "a second mate on the exit picker was captured $(cat "$count_file") times"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a second mate on the exit picker stays quiet, and the poll does not capture the pane"
}

# The away daemon saved this name while the picker was up. Once the pane leaves
# it, the same capture the stale path already takes has to drop the name, or
# the persistence line would still say the dialog is open.
test_closed_exit_picker_drops_saved_dialog_name() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case exit-picker-closed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-picker-closed"
  printf 'idle at the prompt\n' > "$capture_file"
  prime_picker_window "$state" closer "$window" ship "$capture_file" 'working: parked between turns' >/dev/null
  printf '%s' 'Claude background-task exit picker' > "$state/.subsuper-dialog-closer"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a closed picker did not take the ordinary stale path: $(cat "$out")"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "a closed picker was not an ordinary stale: $(cat "$out")"
  grep -F 'blocked-on-prompt' "$out" >/dev/null && fail "a closed picker was still named as a dialog: $(cat "$out")"
  [ ! -e "$state/.subsuper-dialog-closer" ] || fail "a closed picker left the saved dialog name"
  unset FM_FAKE_CREW_STATE
  pass "a closed picker drops the saved dialog name, and the stale stays ordinary"
}

watch_triage_run_only

test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_gone_endpoint_reports_once_instead_of_escalating_forever
test_live_and_unproven_endpoints_still_wedge_escalate
test_wedge_guards_absent_config_keeps_the_unchanged_ladder
test_wedge_guard_critical_defers_one_window_at_a_time_up_to_the_cap
test_wedge_guard_failures_fail_open
test_wedge_guard_never_defers_a_gone_endpoint
test_gone_report_rearms_when_the_endpoint_comes_back
test_second_death_after_a_same_window_relaunch_reports_in_full
test_identical_dead_display_of_a_successor_still_reports
test_busy_pane_below_turn_age_bound_is_absorbed
test_busy_pane_stable_hash_escalates_past_turn_age_bound
test_busy_pane_changing_hash_escalates_past_turn_age_bound
test_busy_pane_turn_end_touch_resets_age
test_busy_pane_native_progress_resets_age
test_busy_pane_claude_tool_progress_resets_age
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_pane_default_turn_age_bound_is_3600s
test_busy_declared_pause_is_rechecked_not_wedge_escalated
test_afk_busy_declared_pause_hands_off_plain_stale
test_afk_busy_declared_pause_ticking_pane_hands_off_once
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_wedge_escalation_deferred_while_worktree_is_written
test_write_deferral_resurfaces_on_the_bounded_cadence
test_crew_worktree_process_live_classifier
test_worktree_process_probe_is_wall_clock_bounded
test_wedge_escalation_deferred_while_worktree_process_runs
test_process_deferral_resurfaces_on_the_bounded_cadence
test_exit_picker_stale_names_the_dialog
test_exit_picker_wedge_keeps_climbing
test_quoted_exit_picker_stays_ordinary_stale
test_secondmate_exit_picker_stays_quiet
test_closed_exit_picker_drops_saved_dialog_name
