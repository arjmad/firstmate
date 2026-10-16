#!/usr/bin/env bash
# Behavior tests for the primary-session blocking-question guard: the tracked
# hook registration and the PreToolUse classifier, scoped to a primary home
# whose fleet needs supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-question-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-question-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

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
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
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
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[question-park]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

test_denies_blocking_question_while_work_is_under_way() {
  give_work "$STATE"
  expect_deny "blocking question with work under way" AskUserQuestion
  expect_deny "case-insensitive name" askuserquestion
  pass "AskUserQuestion is denied in a primary home whose fleet needs supervision"
}

test_deny_names_the_non_blocking_route() {
  local actual
  give_work "$STATE"
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
  [ "$rc" -eq 2 ] || fail "a marked secondmate home with work under way must be guarded, got exit $rc"
  pass "a marked secondmate home is guarded even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  give_work "$STATE"
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
  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[].command' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "tracked .claude/settings.json registers no AskUserQuestion PreToolUse hook"
  mkdir -p "$PRIMARY/bin"
  ln -sf "$CHECK" "$PRIMARY/bin/fm-question-pretool-check.sh"
  ln -sf "$ROOT/bin/fm-primary-scope-lib.sh" "$PRIMARY/bin/fm-primary-scope-lib.sh"
  ln -sf "$ROOT/bin/fm-supervision-lib.sh" "$PRIMARY/bin/fm-supervision-lib.sh"
  give_work "$STATE"
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT CLAUDE_PROJECT_DIR="$PRIMARY" \
      FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      bash -c "$cmd" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "the tracked registration must deny AskUserQuestion with work under way, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "the tracked registration wrote stdout on deny: $(cat "$OUT")"
  pass "the tracked Claude registration routes AskUserQuestion to the guard"
}

test_denies_blocking_question_while_work_is_under_way
test_deny_names_the_non_blocking_route
test_idle_home_keeps_the_question_tool
test_other_tools_are_never_classified
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_malformed_transport_fails_open
test_tracked_claude_registration_reaches_the_guard
