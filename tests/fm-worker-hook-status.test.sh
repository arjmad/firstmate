#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-hook-status.sh, the writer a Claude Code
# crewmate's StopFailure, SessionEnd, and idle_prompt hooks call to append its
# own status line. Each case arms a real busy-state incarnation through
# bin/fm-busy-event.sh, binds the worker session the way the UserPromptSubmit
# hook does, feeds the writer a hook payload, and reads the status log back
# through bin/fm-classify-lib.sh, the reader the watcher uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-hook-status)
WRITER="$ROOT/bin/fm-worker-hook-status.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"
SESSION=worker-session

# new_case <name>: a home with an armed, session-bound incarnation of task t1.
# Sets STATE, CONFIG, and GEN.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  STATE="$dir/state"
  CONFIG="$dir/config"
  GEN=$("$BUSY" arm "$STATE" t1) || fail "could not arm t1"
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$SESSION" \
    | "$BUSY" apply "$STATE" t1 busy --gen "$GEN" --source claude-hook --event user-prompt-submit --session-from-payload \
    || fail "could not bind the worker session"
}

# hook <subcommand> <payload-json> [gen]: run the writer as a hook would.
hook() {
  printf '%s' "$2" | "$WRITER" "$1" "$STATE" t1 --gen "${3:-$GEN}" --config "$CONFIG"
}

status_lines() { [ -f "$STATE/t1.status" ] && grep -c . "$STATE/t1.status" || echo 0; }
last_line() { last_status_line "$STATE/t1.status"; }

test_idle_after_working_declares_a_pause_once() {
  local out
  new_case idle-working
  printf 'working [at=1]: implementing\n' > "$STATE/t1.status"
  hook idle '{"session_id":"worker-session","notification_type":"idle_prompt"}' || fail "idle hook failed"
  out=$(last_line)
  status_is_paused "$out" || fail "an idle worker whose last status was working must read as a declared pause, got '$out'"
  assert_contains "$out" "idle_prompt hook" "the pause must name the hook that wrote it"
  hook idle '{"session_id":"worker-session","notification_type":"idle_prompt"}' || fail "repeated idle hook failed"
  [ "$(status_lines)" -eq 2 ] || fail "a repeated idle_prompt must append nothing, log:"$'\n'"$(cat "$STATE/t1.status")"
  pass "idle_prompt after a working line appends one paused line"
}

test_idle_leaves_an_accounted_quiet_alone() {
  local line
  for line in 'paused [at=1]: waiting on CI' 'gate-wait [at=1]: checks' 'done [at=1]: PR https://example.invalid/pr/1 checks green' \
    'needs-decision [at=1]: pick one' 'ready [at=1]: PR https://example.invalid/pr/1'; do
    new_case "idle-accounted-${line%% *}"
    printf '%s\n' "$line" > "$STATE/t1.status"
    hook idle '{"session_id":"worker-session","notification_type":"idle_prompt"}' || fail "idle hook failed after '$line'"
    [ "$(status_lines)" -eq 1 ] || fail "idle_prompt must not append after '$line', log:"$'\n'"$(cat "$STATE/t1.status")"
  done
  new_case idle-open-decision
  printf 'blocked [at=1]: need a login\nworking [at=2]: other part\n' > "$STATE/t1.status"
  hook idle '{"session_id":"worker-session","notification_type":"idle_prompt"}' || fail "idle hook failed"
  [ "$(status_lines)" -eq 2 ] || fail "idle_prompt must not append while a blocker stays open"
  new_case idle-other-type
  printf 'working [at=1]: x\n' > "$STATE/t1.status"
  hook idle '{"session_id":"worker-session","notification_type":"permission_prompt"}' || fail "idle hook failed"
  [ "$(status_lines)" -eq 1 ] || fail "only idle_prompt may declare the pause"
  pass "idle_prompt leaves a declared wait, terminal event, open decision, or other notification alone"
}

test_stop_failure_reports_a_blocker() {
  local out open
  new_case stopfail
  printf 'working [at=1]: x\n' > "$STATE/t1.status"
  hook stop-failure '{"session_id":"worker-session","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}' \
    || fail "stop-failure hook failed"
  out=$(last_line)
  status_is_captain_relevant "$out" || fail "an API-error turn end must be a blocker firstmate sees, got '$out'"
  assert_contains "$out" "rate_limit: API Error: Rate limit reached" "the blocker must carry the error type and message"
  open=$(status_open_decisions "$STATE/t1.status")
  [ -n "$open" ] || fail "the StopFailure blocker must stay open until resolved"
  hook stop-failure '{"session_id":"worker-session","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}'
  [ "$(status_lines)" -eq 2 ] || fail "an identical StopFailure on top of its own line must append nothing"
  pass "StopFailure appends one blocked line naming the error"
}

test_stop_failure_account_errors_wait_on_the_captain() {
  local out
  new_case stopfail-auth
  hook stop-failure '{"session_id":"worker-session","error":"authentication_failed","last_assistant_message":"Please run /login\nnow"}' \
    || fail "stop-failure hook failed"
  out=$(last_line)
  case "$out" in
    'blocked [on=captain] [at='*']: Claude Code turn ended on API error authentication_failed: Please run /login now;'*) ;;
    *) fail "an authentication failure must be a captain-tagged blocker on one line, got '$out'" ;;
  esac
  new_case stopfail-odd
  hook stop-failure '{"session_id":"worker-session","error":"Weird Value; rm -rf"}' || fail "stop-failure hook failed"
  assert_contains "$(last_line)" "API error unknown" "an unrecognized error value must be reported as unknown"
  pass "StopFailure on an account error tags the blocker for the captain"
}

test_session_end_reports_an_unexpected_exit() {
  local out
  new_case end-other
  printf 'working [at=1]: x\n' > "$STATE/t1.status"
  hook session-end '{"session_id":"worker-session","reason":"other"}' || fail "session-end hook failed"
  out=$(last_line)
  case "$out" in
    'blocked [at='*']: Claude Code session ended (other) before the task reported done or failed'*) ;;
    *) fail "an unexpected exit must be a blocker, got '$out'" ;;
  esac
  new_case end-logout
  hook session-end '{"session_id":"worker-session","reason":"logout"}' || fail "session-end hook failed"
  assert_contains "$(last_line)" "blocked [on=captain]" "a logout needs the captain's login"
  pass "SessionEnd reports an exit nobody asked for as a blocker"
}

test_session_end_skips_ordinary_ends() {
  local reason
  for reason in clear resume; do
    new_case "end-$reason"
    printf 'working [at=1]: x\n' > "$STATE/t1.status"
    hook session-end "{\"session_id\":\"worker-session\",\"reason\":\"$reason\"}" || fail "session-end hook failed"
    [ "$(status_lines)" -eq 1 ] || fail "reason $reason keeps the process running and must append nothing"
  done
  new_case end-after-done
  printf 'done [at=1]: PR https://example.invalid/pr/1 checks green\n' > "$STATE/t1.status"
  hook session-end '{"session_id":"worker-session","reason":"prompt_input_exit"}' || fail "session-end hook failed"
  [ "$(status_lines)" -eq 1 ] || fail "an exit after done must append nothing"
  pass "SessionEnd stays quiet for clear, resume, and an exit after done"
}

test_session_end_honours_firstmates_own_stop() {
  new_case end-expected
  printf 'ready [at=1]: PR https://example.invalid/pr/1\n' > "$STATE/t1.status"
  "$WRITER" expect-exit "$STATE" t1 || fail "expect-exit failed"
  hook session-end '{"session_id":"worker-session","reason":"prompt_input_exit"}' || fail "session-end hook failed"
  [ "$(status_lines)" -eq 1 ] || fail "firstmate's own stop must not be reported, log:"$'\n'"$(cat "$STATE/t1.status")"

  # A record older than the window, or for an earlier incarnation, no longer covers an exit.
  printf '%s %s\n' "$GEN" "$(( $(date +%s) - 700 ))" > "$STATE/t1.exit-expected"
  hook session-end '{"session_id":"worker-session","reason":"other"}' || fail "session-end hook failed"
  [ "$(status_lines)" -eq 2 ] || fail "an expired expect-exit record must not hide an exit"
  new_case end-expected-old-gen
  printf 'g-earlier %s\n' "$(date +%s)" > "$STATE/t1.exit-expected"
  hook session-end '{"session_id":"worker-session","reason":"other"}' || fail "session-end hook failed"
  [ "$(status_lines)" -eq 1 ] || fail "an earlier incarnation's expect-exit record must not hide this one's exit"
  pass "SessionEnd stays quiet for an exit firstmate itself started, and only that one"
}

test_refuses_other_incarnations_and_sessions() {
  local rc
  new_case refuse
  printf 'working [at=1]: x\n' > "$STATE/t1.status"
  hook session-end '{"session_id":"worker-session","reason":"other"}' g-stale; rc=$?
  [ "$rc" -eq 1 ] || fail "a stale gen must be refused with 1, got $rc"
  hook session-end '{"session_id":"nested-session","reason":"other"}'; rc=$?
  [ "$rc" -eq 3 ] || fail "a nested session must be refused with 3, got $rc"
  hook idle '{"notification_type":"idle_prompt"}'; rc=$?
  [ "$rc" -eq 1 ] || fail "a payload with no session must be refused, got $rc"
  [ "$(status_lines)" -eq 1 ] || fail "a refused hook must append nothing"
  pass "the writer refuses a superseded incarnation and a nested session"
}

test_idle_after_working_declares_a_pause_once
test_idle_leaves_an_accounted_quiet_alone
test_stop_failure_reports_a_blocker
test_stop_failure_account_errors_wait_on_the_captain
test_session_end_reports_an_unexpected_exit
test_session_end_skips_ordinary_ends
test_session_end_honours_firstmates_own_stop
test_refuses_other_incarnations_and_sessions
