#!/usr/bin/env bash
# Behavior tests for bin/fm-helm-refresh.sh: when a request is refused, and
# that a granted request's detached owner gives up without typing anything
# when the pane never proves idle or the session changes under it.
#
# The session that holds the lock is a bash symlinked as `claude`, so the
# script's lock-ownership proof sees a real harness ancestor. tmux is pointed
# at an empty socket directory, so no pane on any real server is ever read or
# typed into; the live proof of the /clear path is in
# docs/verification/supervision.md "Helm refresh by /clear".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-helm-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-helm-refresh)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
EMPTY_TMUX="$TMP_ROOT/tmux"
mkdir -p "$EMPTY_TMUX"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
SID=11111111-2222-3333-4444-555555555555

prepare_case() {  # <name>
  CASE_HOME="$TMP_ROOT/cases/$1"
  CASE_STATE="$CASE_HOME/state"
  CASE_CONFIG="$CASE_HOME/config"
  mkdir -p "$CASE_STATE" "$CASE_CONFIG"
  printf 'tokens=1000\nrestart=1\n' > "$CASE_CONFIG/stow-guard"
  printf '%s\n' "$SID" > "$CASE_STATE/.lock-session"
  write_offer "$SID" "$(date +%s)"
}

write_offer() {  # <sid> <at>
  jq -n --arg sid "$1" --argjson at "$2" \
    '{asked:$at, fired:{}, offer:{sid:$sid, at:$at}}' > "$CASE_STATE/.stow-guard.json"
}

SESSIONS=()
# shellcheck disable=SC2329 # EXIT trap.
stop_sessions() {
  local pid
  for pid in "${SESSIONS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -- "-$pid" 2>/dev/null || true
  done
}
trap stop_sessions EXIT

# run_as_session <subcommand> [env assignments...]
# The fake harness records its own pid as the lock holder, runs the script as
# its child inside a pretend tmux pane unless TMUX_PANE= is passed, publishes
# the exit status, and then stays alive as the session the lock names, in its
# own process group so the EXIT trap can stop it and its sleep together.
run_as_session() {
  local sub=$1 rc_file="$CASE_HOME/request.rc" pid
  shift
  : > "$OUT"
  : > "$ERR"
  rm -f "$rc_file"
  set -m
  # The trailing `:` keeps bash from exec'ing sleep as the -c string's last
  # command, which would change the lock pid's process identity mid-test.
  # shellcheck disable=SC2016 # the session script expands its own arguments.
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u TMUX \
    TMUX_PANE=%424242 TMUX_TMPDIR="$EMPTY_TMUX" \
    FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$@" \
    "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$1/.lock"; "$2" "$3" >"$5" 2>"$6"; printf "%s\n" "$?" > "$4.tmp"; mv "$4.tmp" "$4"; sleep 120; :' _ \
    "$CASE_STATE" "$SCRIPT" "$sub" "$rc_file" "$OUT" "$ERR" </dev/null >/dev/null 2>&1 &
  pid=$!
  set +m
  SESSIONS+=("$pid")
  wait_until 30 test -f "$rc_file" || fail "the fake session never finished its $sub"
  return "$(cat "$rc_file")"
}

assert_refused() {  # <label> <needle>
  local label=$1 needle=$2 rc=0
  shift 2
  run_as_session request "$@" || rc=$?
  [ "$rc" -eq 1 ] || fail "$label: expected refusal exit 1, got $rc: $(cat "$OUT") $(cat "$ERR")"
  grep -qF "$needle" "$ERR" || fail "$label: refusal did not say '$needle': $(cat "$ERR")"
  [ ! -e "$CASE_STATE/.helm-refresh-pending" ] || fail "$label: a refused request left a pending record"
}

wait_until() {  # <seconds> <command...>
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

# owner_finished: the detached owner wrote a final log line.
owner_finished() {
  grep -Eq $'\t(gave-up|failed|finished)\t' "$CASE_STATE/.helm-refresh.log" 2>/dev/null
}

test_refusals() {
  prepare_case no-opt-in
  : > "$CASE_CONFIG/stow-guard"
  assert_refused "no opt-in" "config/stow-guard does not hold restart=1"

  prepare_case no-offer
  rm -f "$CASE_STATE/.stow-guard.json"
  assert_refused "no offer" "made no restart offer to this session"

  prepare_case other-session
  write_offer other-session "$(date +%s)"
  assert_refused "offer to another session" "made no restart offer to this session"

  prepare_case stale-offer
  write_offer "$SID" "$(( $(date +%s) - 7300 ))"
  assert_refused "stale offer" "is older than 7200s"

  prepare_case no-pane
  assert_refused "no pane" "runs in no tmux or Herdr pane" TMUX_PANE=

  prepare_case afk
  : > "$CASE_STATE/.afk"
  assert_refused "away mode" "away mode is on"

  prepare_case afk-contract
  : > "$CASE_STATE/.afk-contract"
  assert_refused "away mode starting" "away mode is on"

  prepare_case cooldown
  printf '%s\tcleared\ttoken=x\n' "$(( $(date +%s) - 60 ))" > "$CASE_STATE/.helm-refresh.log"
  assert_refused "recent clear" "less than 3600s ago"

  # A /clear whose re-key came too late logs only `typed`, and still counts.
  prepare_case cooldown-typed
  printf '%s\ttyped\ttoken=x\n' "$(( $(date +%s) - 60 ))" > "$CASE_STATE/.helm-refresh.log"
  assert_refused "recent typed clear" "less than 3600s ago"

  prepare_case foreign-lock
  local rc=0
  : > "$OUT"
  : > "$ERR"
  # The lock names this test's own shell, which is not a harness.
  printf '%s\n' "$$" > "$CASE_STATE/.lock"
  env -u HERDR_ENV -u TMUX TMUX_PANE=%424242 TMUX_TMPDIR="$EMPTY_TMUX" \
    FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$SCRIPT" request >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 1 ] || fail "foreign lock: expected refusal, got $rc"
  grep -qF "not in the session that holds the firstmate session lock" "$ERR" \
    || fail "foreign lock: wrong refusal: $(cat "$ERR")"
  pass "request refuses without the opt-in, a matching fresh offer, a pane, the lock, outside away mode, and inside the cooldown"
}

test_granted_request_gives_up_without_typing() {
  local rc=0
  prepare_case granted
  run_as_session request FM_HELM_REFRESH_WAIT=2 FM_HELM_REFRESH_POLL=1 || rc=$?
  [ "$rc" -eq 0 ] || fail "granted request must exit 0, got $rc: $(cat "$ERR")"
  grep -qF "requested; end the turn now" "$OUT" || fail "granted request did not say so: $(cat "$OUT")"
  grep -q $'\trequested\t.*transport=tmux' "$CASE_STATE/.helm-refresh.log" \
    || fail "granted request was not logged: $(cat "$CASE_STATE/.helm-refresh.log")"
  wait_until 30 owner_finished || fail "the owner never finished: $(cat "$CASE_STATE/.helm-refresh.log")"
  grep -q $'\tgave-up\t.*did not end within 2s; nothing was typed' "$CASE_STATE/.helm-refresh.log" \
    || fail "an unprovable pane did not end in a clean give-up: $(cat "$CASE_STATE/.helm-refresh.log")"
  ! grep -q $'\tcleared\t' "$CASE_STATE/.helm-refresh.log" || fail "an unprovable pane was cleared"
  [ ! -e "$CASE_STATE/.helm-refresh-pending" ] || fail "the give-up left its pending record"
  [ ! -e "$CASE_STATE/.helm-refresh-owner" ] || fail "the give-up left its owner record"
  pass "a granted request starts a detached owner that gives up untouched when the pane never proves idle"
}

test_session_change_stops_the_owner() {
  local rc=0
  prepare_case session-change
  run_as_session request FM_HELM_REFRESH_WAIT=60 FM_HELM_REFRESH_POLL=1 || rc=$?
  [ "$rc" -eq 0 ] || fail "request must exit 0, got $rc: $(cat "$ERR")"
  printf 'another-session\n' > "$CASE_STATE/.lock-session"
  wait_until 30 owner_finished || fail "the owner never finished: $(cat "$CASE_STATE/.helm-refresh.log")"
  grep -q $'\tgave-up\t.*the session changed before the clear; nothing was typed' "$CASE_STATE/.helm-refresh.log" \
    || fail "a changed session did not stop the owner: $(cat "$CASE_STATE/.helm-refresh.log")"

  prepare_case removed
  rc=0
  run_as_session request FM_HELM_REFRESH_WAIT=60 FM_HELM_REFRESH_POLL=1 || rc=$?
  [ "$rc" -eq 0 ] || fail "request must exit 0, got $rc: $(cat "$ERR")"
  rm -f "$CASE_STATE/.helm-refresh-pending"
  wait_until 30 owner_finished || fail "the owner never finished: $(cat "$CASE_STATE/.helm-refresh.log")"
  grep -q $'\tgave-up\t.*the request was replaced or removed; nothing was typed' "$CASE_STATE/.helm-refresh.log" \
    || fail "a removed request did not stop the owner: $(cat "$CASE_STATE/.helm-refresh.log")"

  prepare_case opt-out
  rc=0
  run_as_session request FM_HELM_REFRESH_WAIT=60 FM_HELM_REFRESH_POLL=1 || rc=$?
  [ "$rc" -eq 0 ] || fail "request must exit 0, got $rc: $(cat "$ERR")"
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  wait_until 30 owner_finished || fail "the owner never finished: $(cat "$CASE_STATE/.helm-refresh.log")"
  grep -q $'\tgave-up\t.*no longer holds restart=1; nothing was typed' "$CASE_STATE/.helm-refresh.log" \
    || fail "a withdrawn opt-in did not stop the owner: $(cat "$CASE_STATE/.helm-refresh.log")"
  pass "the owner stops without typing when the session changes, the request is removed, or the opt-in is withdrawn"
}

test_status_and_usage() {
  local rc=0
  prepare_case status
  FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_STATE" "$SCRIPT" status >"$OUT" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "status must exit 0, got $rc"
  grep -qx 'pending: none' "$OUT" || fail "status without a request: $(cat "$OUT")"
  rc=0
  "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown subcommand must exit 2, got $rc"
  "$SCRIPT" --help | grep -q 'fm-helm-refresh.sh request' || fail "--help does not show usage"
  pass "status reports no request, --help prints usage, and an unknown subcommand is a usage error"
}

fm_test_run \
  test_refusals \
  test_granted_request_gives_up_without_typing \
  test_session_change_stops_the_owner \
  test_status_and_usage
