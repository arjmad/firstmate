#!/usr/bin/env bash
# Behavior tests for the primary-session blocking-question guard: the tracked
# hook registration and the PreToolUse classifier, scoped to a primary home
# whose fleet needs supervision, with its captain-presence allowance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-question-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-question-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

CONFIG="$PRIMARY/config"
TRANSCRIPT="$TMP_ROOT/transcript.jsonl"

mkdir -p "$PRIMARY/bin" "$STATE" "$CONFIG"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
: > "$TRANSCRIPT"
# The supervision host's engine must exist for a keeper to be possible; the
# guard only checks that it is there.
ENGINE_STUB="$TMP_ROOT/engine"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ENGINE_STUB"
chmod +x "$ENGINE_STUB"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$ENGINE_STUB"
unset FM_ALLOW_QUESTION_TOOL FM_QUESTION_PRESENT_SECONDS

# This shell is the fixture session's lock holder, so the main-session key the
# mirror and the answered stamp are keyed to is its own.
printf '%s\n' "$$" > "$STATE/.lock"
main_key() {
  FM_STATE_OVERRIDE="$STATE" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-engine-lib.sh"; fm_supervision_host_main_key "$2"' _ "$ROOT" "$STATE"
}
KEY=$(main_key) || fail "fixture: no main-session key for the lock holder"
# The captain's newest prompt in the dialog mirror, <age> seconds ago.
captain_said() {  # <age-seconds> [key]
  rm -f "$STATE/.question-answered"
  jq -cn --argjson epoch "$(( $(date +%s) - $1 ))" --arg key "${2:-$KEY}" \
    '{seq: 1, epoch: $epoch, key: $key, id: "p1", tag: "captain", text: "grill me"}' > "$STATE/.host-mirror.jsonl"
}
# He answered a question <age> seconds ago.
captain_answered() {  # <age-seconds> [key]
  rm -f "$STATE/.host-mirror.jsonl"
  printf '%s\t%s\n' "$(( $(date +%s) - $1 ))" "${2:-$KEY}" > "$STATE/.question-answered"
}
captain_silent() {
  rm -f "$STATE/.host-mirror.jsonl" "$STATE/.question-answered"
}

# One in-flight task is the plainest supervision need (bin/fm-supervision-lib.sh).
give_work() {  # <state-dir>
  printf 'window=fixture\n' > "$1/fixture-task.meta"
}
clear_work() {  # <state-dir>
  rm -f "$1/fixture-task.meta"
}

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" "$@" \
    "$CHECK" --claude --tool "$tool" --transcript "$TRANSCRIPT" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[question-park]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

test_denies_blocking_question_while_work_is_under_way() {
  give_work "$STATE"
  captain_silent
  expect_deny "blocking question with work under way" AskUserQuestion
  expect_deny "case-insensitive name" askuserquestion
  pass "AskUserQuestion is denied in a primary home whose fleet needs supervision"
}

test_deny_names_the_non_blocking_route() {
  local actual
  give_work "$STATE"
  captain_silent
  run_tool AskUserQuestion && fail "work-under-way case must deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"final message"*"end the turn"*) ;;
    *) fail "deny must route the question to the final message and a turn end: $actual" ;;
  esac
  case "$actual" in
    *"only the item that needs the answer waits"*) ;;
    *) fail "deny must keep the rest of the work moving: $actual" ;;
  esac
  pass "the deny tells the primary to ask in its final message and end the turn"
}

test_idle_home_keeps_the_question_tool() {
  clear_work "$STATE"
  expect_allow "idle home" AskUserQuestion
  pass "with nothing to supervise, a question cannot park the fleet and stays allowed"
}

test_other_tools_are_never_classified() {
  local tool
  give_work "$STATE"
  for tool in Bash Read Edit Write Agent AskUser UserQuestion AskUserQuestions \
              mcp__acme__ask_user_question; do
    expect_allow "non-question tool" "$tool"
  done
  pass "only the exact blocking question tool name is classified"
}

test_escape_hatch_allows_deliberate_use() {
  local rc value
  give_work "$STATE"
  captain_said 3600
  expect_allow "escape hatch set" AskUserQuestion FM_ALLOW_QUESTION_TOOL=1
  for value in '' 0 yes true 11; do
    rc=0
    run_tool AskUserQuestion "FM_ALLOW_QUESTION_TOOL=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_QUESTION_TOOL='$value' must not release the guard, got exit $rc"
  done
  pass "the escape hatch releases the guard only on the exact opt-in value"
}

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  give_work "$child/state"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool AskUserQuestion > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "task-worktree no-op wrote output"

  mkdir -p "$plain/bin" "$plain/state"
  git -C "$plain" init -q
  give_work "$plain/state"
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool AskUserQuestion > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the guard is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  give_work "$second/state"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool AskUserQuestion > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home with work under way and no present captain must be guarded, got exit $rc"
  pass "a marked secondmate home is guarded even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  give_work "$STATE"
  captain_silent
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"AskUserQuestion"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[question-park]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

test_malformed_transport_fails_open() {
  local rc payload
  give_work "$STATE"
  captain_silent
  for payload in '{not-json' '' '{}' '{"tool_name":null}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and tool-name-less payloads fail open"
}

test_tracked_claude_registration_reaches_the_guard() {
  # The tracked matcher must route AskUserQuestion to this guard, and the
  # registered command must deny it in a primary home with work under way.
  local cmd rc=0
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[].command
    | select(contains("fm-question-pretool-check.sh"))' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "tracked .claude/settings.json registers no AskUserQuestion PreToolUse hook"
  local f
  mkdir -p "$PRIMARY/bin"
  for f in "$ROOT"/bin/*; do
    ln -sf "$f" "$PRIMARY/bin/${f##*/}"
  done
  give_work "$STATE"
  captain_silent
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$PRIMARY" \
      FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      bash -c "$cmd" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "the tracked registration must deny AskUserQuestion with work under way, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "the tracked registration wrote stdout on deny: $(cat "$OUT")"
  pass "the tracked Claude registration routes AskUserQuestion to the guard"
}

test_present_captain_keeps_the_question_tool() {
  give_work "$STATE"
  captain_said 30
  expect_allow "captain prompted 30 seconds ago" AskUserQuestion
  captain_silent
  captain_answered 30
  expect_allow "captain answered a question 30 seconds ago" AskUserQuestion
  pass "a captain who prompted or answered within the presence window keeps the selector with work under way"
}

test_absent_captain_is_denied() {
  local actual
  give_work "$STATE"
  captain_said 900
  expect_deny "captain prompted 15 minutes ago" AskUserQuestion
  actual=$(jq -r '.systemMessage' "$ERR")
  assert_contains "$actual" "15 minutes ago, outside the 10-minute presence window" "the deny must say how long the captain has been silent"
  captain_silent
  expect_deny "captain never prompted" AskUserQuestion
  assert_contains "$(jq -r '.systemMessage' "$ERR")" "has sent no message in this session" "the deny must say the captain never spoke"
  # Presence belongs to this main session only.
  captain_said 30 "0:0:0"
  expect_deny "captain prompted in another session" AskUserQuestion
  captain_silent
  captain_answered 30 "0:0:0"
  expect_deny "captain answered in another session" AskUserQuestion
  pass "a captain silent past the window, or present only in another session, gets today's deny"
}

test_presence_window_is_configurable() {
  give_work "$STATE"
  captain_said 900
  expect_allow "a 20-minute window" AskUserQuestion FM_QUESTION_PRESENT_SECONDS=1200
  expect_deny "a 5-minute window" AskUserQuestion FM_QUESTION_PRESENT_SECONDS=300
  expect_deny "a malformed window keeps the default" AskUserQuestion FM_QUESTION_PRESENT_SECONDS=soon
  pass "FM_QUESTION_PRESENT_SECONDS sets the presence window and a malformed value keeps ten minutes"
}

test_present_captain_without_a_keeper_is_denied() {
  local rc=0
  give_work "$STATE"
  captain_said 30
  : > "$CONFIG/supervision-host-off"
  expect_deny "a home that opted out of the supervision host" AskUserQuestion
  assert_contains "$(jq -r '.systemMessage' "$ERR")" "nothing can keep supervision running while it waits: the home does not run the supervision host" \
    "the deny must name why no keeper can run"
  rm -f "$CONFIG/supervision-host-off"
  expect_deny "no engine executable" AskUserQuestion FM_SUPERVISION_ENGINE_CLAUDE_BIN="$TMP_ROOT/missing"
  : > "$OUT"; : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$CHECK" --claude --tool AskUserQuestion --transcript "$TMP_ROOT/no-transcript" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable transcript must deny, got exit $rc"
  assert_contains "$(jq -r '.systemMessage' "$ERR")" "the session transcript cannot be read" "the deny must name the unreadable transcript"
  rc=0
  printf '%s' "{\"toolName\":\"AskUserQuestion\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a present captain on a non-Claude transport must deny, got exit $rc"
  pass "a present captain is still denied where no keeper can keep supervision running"
}

test_present_claude_payload_on_stdin_is_allowed() {
  local rc=0
  give_work "$STATE"
  captain_said 30
  : > "$OUT"; : > "$ERR"
  printf '%s' "{\"tool_name\":\"AskUserQuestion\",\"tool_use_id\":\"toolu_1\",\"transcript_path\":\"$TRANSCRIPT\"}" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a Claude payload with a present captain must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "the allow wrote output"
  pass "the Claude payload's transcript path lets a present captain keep the selector"
}

test_denies_blocking_question_while_work_is_under_way
test_deny_names_the_non_blocking_route
test_present_captain_keeps_the_question_tool
test_absent_captain_is_denied
test_presence_window_is_configurable
test_present_captain_without_a_keeper_is_denied
test_present_claude_payload_on_stdin_is_allowed
test_idle_home_keeps_the_question_tool
test_other_tools_are_never_classified
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_malformed_transport_fails_open
test_tracked_claude_registration_reaches_the_guard
