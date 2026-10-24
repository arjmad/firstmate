#!/usr/bin/env bash
# Behavior tests for bin/fm-progress.sh, the read-only progress projection a
# polling display reads: helm state from its lock pid's Claude session record,
# each recorded direct report's phase from its latest status event, its busy
# state through the busy-record owner, and steps from the worker's own Claude
# task list (found through its "<kind>: <id>" session name and a live pid) or a
# [step=n/m] status token.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROGRESS="$ROOT/bin/fm-progress.sh"
TMP_ROOT=$(fm_test_tmproot fm-progress)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A pid that is provably not running: a reaped child of this shell.
dead_pid() {
  sleep 0 &
  local pid=$!
  wait "$pid" 2>/dev/null
  printf '%s' "$pid"
}

new_home() {  # <name> -> echoes the home path
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/config" "$TMP_ROOT/$1-claude/sessions" "$TMP_ROOT/$1-claude/tasks"
  printf '%s' "$home"
}

session() {  # <claude-dir> <pid> <name> <session-id> <started-ms> [status] [status-ms]
  printf '{"pid":%s,"sessionId":"%s","kind":"interactive","name":"%s","startedAt":%s,"status":"%s","statusUpdatedAt":%s}\n' \
    "$2" "$4" "$3" "$5" "${6:-busy}" "${7:-$5}" > "$1/sessions/$2.json"
}

task() {  # <claude-dir> <session-id> <n> <subject> <status>
  mkdir -p "$1/tasks/$2"
  printf '{"id":"%s","subject":"%s","description":"","status":"%s","blocks":[],"blockedBy":[]}\n' \
    "$3" "$4" "$5" > "$1/tasks/$2/$3.json"
}

arm_busy() {  # <state> <id> <state> <source>
  printf 'g1\n' > "$1/$2.busy-gen"
  printf 'v1 gen=g1 seq=2 state=%s source=%s event=e ts=1\n' "$3" "$4" > "$1/$2.busy-state"
}

run_json() {  # <home> [claude-config-dir]
  FM_HOME=$1 CLAUDE_CONFIG_DIR=${2:-$TMP_ROOT/none} HOME=$TMP_ROOT/nohome "$PROGRESS" --json
}

test_empty_home_has_no_helm_and_no_workers() {
  local home out
  home=$(new_home empty)
  out=$(run_json "$home") || fail "empty home: reader failed"
  assert_equals 'fm-progress/v1|null|0' "$(jq -r '"\(.schema)|\(.helm)|\(.workers | length)"' <<< "$out")" \
    "empty home: schema, no helm, no workers"
  out=$(FM_HOME=$home CLAUDE_CONFIG_DIR=$TMP_ROOT/none "$PROGRESS" --line)
  assert_equals 'fleet: no workers live' "$out" "empty home: --line"
  pass "an empty home projects no helm and no workers"
}

test_claude_worker_steps_come_from_its_live_session_task_list() {
  local home claude now out stale
  home=$(new_home tasklist)
  claude=$TMP_ROOT/tasklist-claude
  now=$(date +%s)
  fm_write_meta "$home/state/demo.meta" kind=ship harness=claude \
    "project=/x/projects/firstmate" "account=$claude" "spawn_gen=s$((now - 600)).1.2"
  printf 'working [at=%s]: writing the reader\n' "$((now - 120))" > "$home/state/demo.status"
  arm_busy "$home/state" demo busy claude-hook
  # The live session carrying the launch name owns the list.
  session "$claude" "$$" "ship: demo" sid-live 2000
  task "$claude" sid-live 1 "Port the reader" completed
  task "$claude" sid-live 2 "Write the tests" in_progress
  task "$claude" sid-live 3 "Open the PR" pending
  task "$claude" sid-live 4 "Dropped idea" deleted
  # A newer record with the same name whose process is gone is never read.
  stale=$(dead_pid)
  session "$claude" "$stale" "ship: demo" sid-dead 9000
  task "$claude" sid-dead 1 "Stale step" completed
  out=$(run_json "$home") || fail "task list: reader failed"
  assert_equals 'demo|ship|claude|firstmate|working|writing the reader|busy|claude-hook' \
    "$(jq -r '.workers[0] | "\(.id)|\(.kind)|\(.harness)|\(.repo)|\(.phase)|\(.text)|\(.busy)|\(.busy_source)"' <<< "$out")" \
    "task list: worker identity, phase, and busy"
  assert_equals '1|3|Write the tests|task-list' \
    "$(jq -r '.workers[0].steps | "\(.done)|\(.total)|\(.current)|\(.source)"' <<< "$out")" \
    "task list: steps from the live session's list, deleted entries dropped"
  assert_equals 'ok' "$(jq -r --argjson now "$now" '.workers[0]
    | if .in_phase_s >= 120 and .in_phase_s < 180 and .elapsed_s >= 600 and .elapsed_s < 660 then "ok" else "\(.)" end' <<< "$out")" \
    "task list: time in phase from [at=], elapsed from spawn_gen"
  out=$(FM_HOME=$home CLAUDE_CONFIG_DIR=$TMP_ROOT/none "$PROGRESS" --line)
  assert_contains "$out" "▶ demo 10m · working 2m · ███░░░░░░░ 1/3 · Write the tests" "task list: --line row"
  pass "a Claude worker's steps come from its live named session's task list"
}

test_status_token_supplies_steps_without_a_task_list() {
  local home now out
  home=$(new_home token)
  now=$(date +%s)
  fm_write_meta "$home/state/codexer.meta" kind=scout harness=codex "spawn_gen=s$now.1.2"
  printf 'working [at=%s]: early\nneeds-decision [at=%s] [step=3/4]: pick A or B\nfree prose continuation\n' \
    "$((now - 900))" "$((now - 240))" > "$home/state/codexer.status"
  out=$(run_json "$home") || fail "token: reader failed"
  assert_equals 'needs-decision|pick A or B|3|4|status-token|unknown' \
    "$(jq -r '.workers[0] | "\(.phase)|\(.text)|\(.steps.done)|\(.steps.total)|\(.steps.source)|\(.busy)"' <<< "$out")" \
    "token: latest event's step token, unarmed busy record reads unknown"
  printf 'working [at=%s] [step=x/4]: bad token\n' "$now" >> "$home/state/codexer.status"
  out=$(run_json "$home")
  assert_equals 'null' "$(jq -c '.workers[0].steps' <<< "$out")" "token: malformed token gives no steps"
  pass "a [step=n/m] token supplies steps when no task list exists"
}

test_task_list_wins_over_a_status_token() {
  local home claude now out
  home=$(new_home both)
  claude=$TMP_ROOT/both-claude
  now=$(date +%s)
  fm_write_meta "$home/state/both.meta" kind=ship harness=claude "account=$claude" "spawn_gen=s$now.1.2"
  printf 'working [at=%s] [step=1/9]: older declaration\n' "$now" > "$home/state/both.status"
  session "$claude" "$$" "ship: both" sid-both 1000
  task "$claude" sid-both 1 "Only step" in_progress
  out=$(run_json "$home")
  assert_equals '0|1|task-list' "$(jq -r '.workers[0].steps | "\(.done)|\(.total)|\(.source)"' <<< "$out")" \
    "both: the task list wins"
  pass "a live task list wins over a status token"
}

test_busy_record_from_an_untrusted_source_reads_unknown() {
  local home out
  home=$(new_home untrusted)
  fm_write_meta "$home/state/w.meta" kind=ship harness=claude
  arm_busy "$home/state" w idle pi-ext
  out=$(run_json "$home")
  assert_equals 'unknown|source-mismatch|starting' "$(jq -r '.workers[0] | "\(.busy)|\(.busy_source)|\(.phase)"' <<< "$out")" \
    "untrusted: pi-ext cannot classify a claude task"
  printf 'g2\n' > "$home/state/w.busy-gen"
  out=$(run_json "$home")
  assert_equals 'unknown|gen-mismatch' "$(jq -r '.workers[0] | "\(.busy)|\(.busy_source)"' <<< "$out")" \
    "untrusted: a stale incarnation reads unknown"
  pass "a busy record that does not validate reads unknown"
}

test_helm_state_comes_from_the_lock_holder_session() {
  local home claude now out
  home=$(new_home helm)
  claude=$TMP_ROOT/helm-claude
  now=$(date +%s)
  printf '%s\n' "$$" > "$home/state/.lock"
  session "$claude" "$$" "firstmate-main" sid-helm "$(((now - 3600) * 1000))" idle "$(((now - 90) * 1000))"
  out=$(run_json "$home" "$claude")
  assert_equals "$$|idle|$((now - 90))|firstmate-main" \
    "$(jq -r '.helm | "\(.pid)|\(.state)|\(.since)|\(.name)"' <<< "$out")" "helm: lock pid's session record"
  # The reader also finds the helm's record through the home's account pin.
  printf '%s\n' "$claude" > "$home/config/claude-account"
  out=$(run_json "$home")
  assert_equals idle "$(jq -r '.helm.state' <<< "$out")" "helm: found through config/claude-account"
  rm "$home/config/claude-account"
  out=$(run_json "$home")
  assert_equals "$$|unknown|null" "$(jq -r '.helm | "\(.pid)|\(.state)|\(.since)"' <<< "$out")" \
    "helm: live lock without a session record reads unknown"
  dead_pid > "$home/state/.lock"
  out=$(run_json "$home" "$claude")
  assert_equals null "$(jq -c '.helm' <<< "$out")" "helm: a dead lock holder is no helm"
  pass "helm state comes from the live lock holder's session record"
}

test_unreadable_task_file_degrades_instead_of_failing() {
  local home claude out
  home=$(new_home torn)
  claude=$TMP_ROOT/torn-claude
  fm_write_meta "$home/state/t.meta" kind=ship harness=claude "account=$claude"
  printf 'working [at=1]: going\n' > "$home/state/t.status"
  session "$claude" "$$" "ship: t" sid-torn 1000
  mkdir -p "$claude/tasks/sid-torn"
  printf '{"id":"1","subject":' > "$claude/tasks/sid-torn/1.json"
  out=$(run_json "$home") || fail "torn: reader failed"
  assert_equals 'working|null' "$(jq -r '.workers[0] | "\(.phase)|\(.steps)"' <<< "$out")" \
    "torn: a half-written task file drops task-list steps only"
  pass "a half-written task file degrades the projection instead of failing it"
}

test_usage() {
  local rc
  "$PROGRESS" --bogus >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "usage: unknown flag"
  "$PROGRESS" --help | grep -q 'usage: fm-progress.sh' || fail "usage: --help"
  pass "usage errors exit 2 and --help prints usage"
}

test_empty_home_has_no_helm_and_no_workers
test_claude_worker_steps_come_from_its_live_session_task_list
test_status_token_supplies_steps_without_a_task_list
test_task_list_wins_over_a_status_token
test_busy_record_from_an_untrusted_source_reads_unknown
test_helm_state_comes_from_the_lock_holder_session
test_unreadable_task_file_degrades_instead_of_failing
test_usage
