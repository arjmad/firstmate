#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-claude-resume.sh, the SessionStart hook that
# reports a Firstmate Claude agent's resume file to Herdr as its resume
# command. A recording fake stands in for Herdr; no Herdr server is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-herdr-claude-resume.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-claude-resume)
FAKE_HERDR="$TMP_ROOT/herdr"
LOG="$TMP_ROOT/herdr.log"
RESUME="$TMP_ROOT/agent.claude-resume.sh"
printf 'echo resumed\n' > "$RESUME"
cat > "$FAKE_HERDR" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$LOG'
SH
chmod +x "$FAKE_HERDR"

in_pane() {  # <command...>: run as a hook inside a Herdr pane
  env HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_SOCKET_PATH="$TMP_ROOT/sock" \
    HERDR_BIN_PATH="$FAKE_HERDR" FM_HERDR_RESUME_DELAYS=0 "$@"
}

payload() {  # <session-id> [extra-json-fields]
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"resume"%s}' "$1" "${2-}"
}

wait_for_log() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$LOG" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_report_sends_the_full_resume_command() {
  local out rc=0
  : > "$LOG"
  out=$(in_pane "$SCRIPT" report "$RESUME" sess-1 resume 2>&1) || rc=$?
  expect_code 0 "$rc" "a report from a Herdr pane should succeed: $out"
  out=$(cat "$LOG")
  assert_contains "$out" "pane report-agent-session w1:p2 --source herdr:claude --agent claude --seq " \
    "the report must come from Herdr's Claude source for this pane"
  assert_contains "$out" "--agent-session-id sess-1 --session-start-source resume -- sh $RESUME sess-1" \
    "the report must carry the session and the resume file as its command"
  [[ "$out" =~ --seq\ ([0-9]{16,})\  ]] || fail "the report --seq must be epoch nanoseconds: $out"
  pass "report: sends the resume file as the pane's resume command"
}

test_hook_reports_after_returning() {
  local rc=0
  : > "$LOG"
  payload sess-2 | in_pane "$SCRIPT" hook "$RESUME" || rc=$?
  expect_code 0 "$rc" "the hook must exit 0"
  wait_for_log || fail "the hook never reported"
  assert_contains "$(cat "$LOG")" "--agent-session-id sess-2 --session-start-source resume -- sh $RESUME sess-2" \
    "the hook must report the payload's session"
  pass "hook: reports the payload's session in the background"
}

test_hook_does_nothing_it_should_not() {
  local name rc
  for name in outside subagent bad-session missing-file relative-file other-event; do
    : > "$LOG"
    rc=0
    case "$name" in
      outside) payload sess-3 | env -u HERDR_ENV -u HERDR_PANE_ID HERDR_BIN_PATH="$FAKE_HERDR" \
        FM_HERDR_RESUME_DELAYS=0 "$SCRIPT" hook "$RESUME" || rc=$? ;;
      subagent) payload sess-3 ',"agent_id":"sub-1"' | in_pane "$SCRIPT" hook "$RESUME" || rc=$? ;;
      bad-session) payload "it's" | in_pane "$SCRIPT" hook "$RESUME" || rc=$? ;;
      missing-file) payload sess-3 | in_pane "$SCRIPT" hook "$TMP_ROOT/absent.sh" || rc=$? ;;
      relative-file) payload sess-3 | in_pane "$SCRIPT" hook agent.claude-resume.sh || rc=$? ;;
      other-event) printf '{"hook_event_name":"Stop","session_id":"sess-3"}' \
        | in_pane "$SCRIPT" hook "$RESUME" || rc=$? ;;
    esac
    expect_code 0 "$rc" "the hook must exit 0 ($name)"
    sleep 0.5
    [ ! -s "$LOG" ] || fail "the hook reported when it must not ($name): $(cat "$LOG")"
  done
  : > "$LOG"
  rc=0
  printf 'not json' | in_pane "$SCRIPT" hook "$RESUME" || rc=$?
  expect_code 0 "$rc" "a malformed payload must not fail Claude's startup"
  pass "hook: stays silent outside Herdr, for a subagent, a bad session or file, or another event"
}

test_report_refuses_outside_a_pane() {
  local rc=0
  : > "$LOG"
  env -u HERDR_ENV HERDR_BIN_PATH="$FAKE_HERDR" "$SCRIPT" report "$RESUME" sess-4 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a report outside a Herdr pane must fail"
  [ ! -s "$LOG" ] || fail "a report outside a Herdr pane must not reach Herdr"
  pass "report: refuses outside a Herdr pane"
}

test_report_sends_the_full_resume_command
test_hook_reports_after_returning
test_hook_does_nothing_it_should_not
test_report_refuses_outside_a_pane
