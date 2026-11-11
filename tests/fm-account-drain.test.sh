#!/usr/bin/env bash
# Tests for bin/fm-account-drain.sh, the opt-in two-account Claude drain: the
# helm account-move check, the helm self-handover, the both-accounts-low
# answer, and bin/fm-spawn.sh's refusal on that answer.
#
# Helms are real processes: a bash executable reached through a symlink named
# claude, so the session lock's ancestry walk (bin/fm-session-lock-lib.sh)
# identifies it as a Claude harness exactly as it does a real one. The live
# session running this suite is kept out by scrubbing CLAUDE_PID,
# CLAUDE_CODE_SESSION_ID and CLAUDECODE, and the walk stops at this suite's own
# non-harness shell. No real account, notify path or Herdr server is touched:
# the notify and handover commands are fixture scripts, and the only Herdr is a
# fake that answers one pane as alive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRAIN="$ROOT/bin/fm-account-drain.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-drain)
BASE_PATH=${FM_TEST_BASE_PATH:-$PATH}
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/bin")
ln -s "$(command -v bash)" "$FAKEBIN/claude"
STORE_ECO="$TMP_ROOT/stores/claude-ecomills"
mkdir -p "$STORE_ECO"
HELM_PIDS=()

cleanup_helms() {
  local pid
  for pid in ${HELM_PIDS[@]+"${HELM_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  HELM_PIDS=()
}
trap 'cleanup_helms; fm_test_cleanup' EXIT

make_home() {  # <name>: a configured home whose launch line names ecomills
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf 'CLAUDE_CONFIG_DIR=%s claude --model opus\n' "$STORE_ECO" > "$home/config/primary-harness"
  cat > "$home/config/account-drain" <<EOF
# fixture
drain_file=$home/drain.json
account.ecomills=$STORE_ECO
account.main=ordinary
label.ecomills=arjun@ecomills.com
label.main=arjmad@gmail.com
handover_marker=$home/marker.json
EOF
  printf '%s\n' "$home"
}

drain() {  # <home> <age-seconds> <both_low> [launch_line_account]
  local now
  now=$(date +%s)
  jq -cn --argjson t $((now - $2)) --argjson low "$3" --arg line "${4:-}" '
    {version: 1, t: $t, seats: {}, stage: "stage1", both_low: $low,
     resets: {ecomills: 1794963600, main: 1795050000},
     week_left: {ecomills: 1, main: 1}}
    + (if $line == "" then {} else {launch_line_account: $line} end)' > "$1/drain.json"
}

clean_env() {
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS "$@"
}

run_drain() {  # <home> <subcommand...>
  local home=$1
  shift
  clean_env FM_HOME="$home" FM_ROOT_OVERRIDE='' PATH="$FAKEBIN:$BASE_PATH" "$DRAIN" "$@"
}

# start_helm <home> <store|ordinary> <dir>: a fake Claude helm that takes the
# session lock, records its session, then loops; touching <dir>/go makes it run
# handover once (output to <dir>/handover.out, exit code on its last line), and
# touching <dir>/start makes it run session start (output to <dir>/start.out).
# Prints the helm's pid once it holds the lock.
start_helm() {
  local home=$1 store=$2 dir=$3 pid i
  local -a store_env=(-u CLAUDE_CONFIG_DIR)
  [ "$store" = ordinary ] || store_env=(CLAUDE_CONFIG_DIR="$store")
  mkdir -p "$dir"
  rm -f "$dir/ready"
  # shellcheck disable=SC2016 # expanded by the helm's own shell
  # env directly, not the clean_env function: a backgrounded function runs in
  # a subshell, and $! must be the helm's own pid.
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS \
    "${store_env[@]}" FM_HOME="$home" FM_ROOT_OVERRIDE='' PATH="$FAKEBIN:$BASE_PATH" \
    FM_ACCOUNT_DRAIN_GRACE="${HELM_GRACE:-1}" FM_ACCOUNT_DRAIN_EXIT_WAIT=10 \
    "$FAKEBIN/claude" -c '
      bin=$0 dir=$1
      "$bin/fm-lock.sh" || exit 1
      "$bin/fm-account-drain.sh" record-session || exit 1
      : > "$dir/ready"
      while :; do
        if [ -f "$dir/go" ]; then
          rm -f "$dir/go"
          "$bin/fm-account-drain.sh" handover > "$dir/handover.out" 2>&1
          echo "exit=$?" >> "$dir/handover.out"
        fi
        if [ -f "$dir/start" ]; then
          rm -f "$dir/start"
          FM_SESSION_START_TIMEOUT=60 "$bin/fm-session-start.sh" > "$dir/start.out" 2>&1
          echo "exit=$?" >> "$dir/start.out"
        fi
        sleep 0.2
      done' "$ROOT/bin" "$dir" >"$dir/helm.log" 2>&1 &
  pid=$!
  HELM_PIDS+=("$pid")
  for i in $(seq 1 100); do
    [ -f "$dir/ready" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  [ -f "$dir/ready" ] || fail "fake helm in $dir did not take the session lock: $(cat "$dir/helm.log" 2>/dev/null)"
  printf '%s\n' "$pid"
}

# helm_handover <dir>: make the helm in <dir> run handover once and wait for it.
helm_handover() {
  rm -f "$1/handover.out"
  touch "$1/go"
  wait_for_file_line "$1/handover.out" "exit=" || fail "handover in $1 did not finish"
}

wait_for_file_line() {  # <file> <pattern> [tenths]
  local i
  for i in $(seq 1 "${3:-150}"); do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

test_unconfigured_home_is_inert() {
  local home="$TMP_ROOT/unconfigured" out rc
  mkdir -p "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/primary-harness"
  out=$(run_drain "$home" check 2>&1)
  assert_equals "" "$out" "an unconfigured check must print nothing"
  rc=0
  run_drain "$home" both-low >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an unconfigured both-low must answer no information"
  rc=0
  out=$(run_drain "$home" handover 2>&1) || rc=$?
  expect_code 1 "$rc" "an unconfigured handover must refuse"
  assert_contains "$out" "not configured" "the refusal must say why"
  run_drain "$home" record-session >/dev/null 2>&1 || true
  assert_absent "$home/state/.account-drain-session" "an unconfigured home must record nothing"
  pass "fm-account-drain: an unconfigured home is inert"
}

test_check_announces_each_move_once() {
  local home dir out
  home=$(make_home move-once)
  dir="$TMP_ROOT/move-once-helm"
  start_helm "$home" "$STORE_ECO" "$dir" >/dev/null
  assert_grep "store=$STORE_ECO" "$home/state/.account-drain-session" "the session record must name the helm's store"
  assert_grep "harness=claude" "$home/state/.account-drain-session" "the session record must see a Claude helm"
  out=$(run_drain "$home" check)
  assert_equals "" "$out" "no move: the check must stay silent"
  printf 'claude --model opus\n' > "$home/config/primary-harness"
  out=$(run_drain "$home" check)
  assert_contains "$out" "account-moved: this helm runs on ecomills and the launch line now names main" \
    "a moved launch line must raise one account-moved line"
  assert_contains "$out" "bin/fm-account-drain.sh handover" "the line must name the handover command"
  out=$(run_drain "$home" check)
  assert_equals "" "$out" "the same move must not be announced twice"
  cleanup_helms
  pass "fm-account-drain: check announces a launch-line move once"
}

test_check_holds_for_away_mode_and_a_disagreeing_drain_file() {
  local home dir out
  home=$(make_home move-hold)
  dir="$TMP_ROOT/move-hold-helm"
  start_helm "$home" "$STORE_ECO" "$dir" >/dev/null
  printf 'claude\n' > "$home/config/primary-harness"
  : > "$home/state/.afk-contract"
  out=$(run_drain "$home" check)
  assert_equals "" "$out" "an away or quiet record must hold the wake"
  rm -f "$home/state/.afk-contract"
  drain "$home" 60 false ecomills
  out=$(run_drain "$home" check)
  assert_equals "" "$out" "a fresh drain file naming another launch account must hold the wake"
  drain "$home" 4000 false ecomills
  out=$(run_drain "$home" check)
  assert_contains "$out" "account-moved:" "a stale drain file must change nothing, so the move is announced"
  cleanup_helms
  pass "fm-account-drain: check holds while away or quiet and while a fresh drain file disagrees"
}

test_check_ignores_an_older_sessions_record() {
  local home dir out
  home=$(make_home move-stale)
  dir="$TMP_ROOT/move-stale-helm"
  start_helm "$home" "$STORE_ECO" "$dir" >/dev/null
  printf 'fm-account-drain-session-v1\npid=999999\nharness=claude\nstore=%s\n' "$STORE_ECO" \
    > "$home/state/.account-drain-session"
  printf 'claude\n' > "$home/config/primary-harness"
  out=$(run_drain "$home" check)
  assert_equals "" "$out" "a record naming another pid than the live lock holder must be ignored"
  cleanup_helms
  pass "fm-account-drain: check ignores a session record the lock holder did not write"
}

test_marker_reports_capability() {
  local home dir
  home=$(make_home marker)
  dir="$TMP_ROOT/marker-helm"
  start_helm "$home" "$STORE_ECO" "$dir" >/dev/null
  assert_equals false "$(jq -r .capable "$home/marker.json")" "no handover command: not capable"
  assert_equals "$home" "$(jq -r .home "$home/marker.json")" "the marker must name its home"
  assert_equals 1 "$(jq -r .version "$home/marker.json")" "the marker must carry version 1"
  printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/marker-start"
  chmod +x "$TMP_ROOT/marker-start"
  printf 'handover_command=%s\n' "$TMP_ROOT/marker-start" >> "$home/config/account-drain"
  run_drain "$home" check >/dev/null
  assert_equals true "$(jq -r .capable "$home/marker.json")" "a configured start command and a Claude helm: capable"
  cleanup_helms
  sleep 0.3
  run_drain "$home" check >/dev/null
  assert_equals false "$(jq -r .capable "$home/marker.json")" "no live helm: not capable"
  pass "fm-account-drain: the capability marker follows the start command and the helm"
}

test_both_low_answers() {
  local home out rc
  home=$(make_home both-low)
  drain "$home" 60 true
  rc=0
  run_drain "$home" both-low >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "with the spill unset, both-low must answer no"
  printf 'both_low_spill=pi openai-codex/gpt-6.1-sol high\n' >> "$home/config/account-drain"
  out=$(run_drain "$home" both-low)
  expect_code 0 $? "a fresh both_low true with the spill on must answer yes"
  assert_contains "$out" "ecomills resets 2026-11-18T01:00:00Z" "the answer must name the ecomills reset"
  assert_contains "$out" "main resets 2026-11-19T01:00:00Z" "the answer must name the main reset"
  assert_contains "$out" "spill: --harness pi --model openai-codex/gpt-6.1-sol --effort high" "the answer must name the spill"
  jq -cn --argjson t "$(date +%s)" '{version: 1, t: $t, both_low: true, resets: "soon"}' > "$home/drain.json"
  out=$(run_drain "$home" both-low)
  assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "both Claude accounts are at or under the floor" \
    "a resets field of another shape must still lead with the reason line"
  assert_contains "$out" "no reset times" "and say no reset times were given"
  drain "$home" 4000 true
  rc=0
  run_drain "$home" both-low >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a stale drain file must answer no information"
  drain "$home" 60 false
  rc=0
  run_drain "$home" both-low >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "both_low false must answer no"
  printf 'not json\n' > "$home/drain.json"
  rc=0
  run_drain "$home" both-low >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an unreadable drain file must answer no information"
  drain "$home" 60 true
  printf 'both_low_spill=off\n' >> "$home/config/account-drain"
  rc=0
  run_drain "$home" both-low >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "the last both_low_spill=off line must switch it off"
  pass "fm-account-drain: both-low answers yes only for a fresh both_low with the spill on"
}

test_spawn_refuses_a_claude_ship_while_both_low() {
  local home proj id=drain-spawn-z1 out rc
  home=$(make_home spawn-refuse)
  proj="$home/projects/project"
  fm_git_init_commit "$proj"
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nx\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf 'both_low_spill=pi openai-codex/gpt-6.1-sol high\n' >> "$home/config/account-drain"
  drain "$home" 60 true
  rc=0
  out=$(clean_env HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness claude --mode direct-PR --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a Claude ship must be refused while both accounts are low"
  assert_contains "$out" "spawn refused - both Claude accounts are at or under the floor" "the refusal must say why"
  assert_contains "$out" "ecomills resets 2026-11-18T01:00:00Z" "the refusal must name both reset times"
  assert_contains "$out" "--harness pi --model openai-codex/gpt-6.1-sol --effort high --dispatch-override" \
    "the refusal must name the spill flags"
  assert_absent "$home/state/$id.meta" "a refused spawn must publish no task record"
  drain "$home" 60 false
  rc=0
  out=$(clean_env HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness claude --mode direct-PR --yolo off 2>&1) || rc=$?
  assert_not_contains "$out" "both Claude accounts" "with one account open the both-low refusal must not fire"
  pass "fm-spawn: a Claude ship is refused while both accounts are low, naming the resets and the spill"
}

test_handover_refusals_leave_the_helm_running() {
  local home dir pid
  home=$(make_home refuse)
  dir="$TMP_ROOT/refuse-helm"
  pid=$(start_helm "$home" "$STORE_ECO" "$dir")
  helm_handover "$dir"
  assert_grep "no account move is pending" "$dir/handover.out" "no move: handover must refuse"
  printf 'claude\n' > "$home/config/primary-harness"
  helm_handover "$dir"
  assert_grep "exit=3" "$dir/handover.out" "an unconfigured start command must exit 3"
  assert_grep "no executable handover_command is configured" "$dir/handover.out" "the report must name the missing start command"
  assert_grep "to move it by hand" "$dir/handover.out" "the report must say what to run by hand"
  printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/refuse-start"
  chmod +x "$TMP_ROOT/refuse-start"
  printf 'handover_command=%s\n' "$TMP_ROOT/refuse-start" >> "$home/config/account-drain"
  assert_contains "$(run_drain "$home" check)" "account-moved:" "the move must be announced"
  assert_equals "" "$(run_drain "$home" check)" "and only once"
  mkdir -p "$home/state/.control-busy-task.lock"
  printf '%s\n' "$$" > "$home/state/.control-busy-task.lock/pid"
  helm_handover "$dir"
  assert_grep "holds a task lock (.control-busy-task.lock)" "$dir/handover.out" "a held task lock must refuse the handover: $(cat "$dir/handover.out")"
  assert_contains "$(run_drain "$home" check)" "account-moved:" "a busy refusal must let the check raise the move again"
  rm -rf "$home/state/.control-busy-task.lock"
  : > "$home/state/.afk"
  helm_handover "$dir"
  assert_grep "away or quiet record exists" "$dir/handover.out" "away mode must refuse the handover"
  rm -f "$home/state/.afk"
  printf '#!/bin/sh\nexit 2\n' > "$TMP_ROOT/refuse-notify-2"
  chmod +x "$TMP_ROOT/refuse-notify-2"
  printf 'notify_command=%s\n' "$TMP_ROOT/refuse-notify-2" >> "$home/config/account-drain"
  helm_handover "$dir"
  assert_grep "notify_command failed" "$dir/handover.out" "a notify command exiting 2 is a failure, not an unconfigured notify"
  wait_for_file_line "$home/state/.account-drain-handover" "status=aborted" || fail "the called-off waiter must stand down"
  printf 'notify_command=false\n' >> "$home/config/account-drain"
  helm_handover "$dir"
  assert_grep "notify_command failed" "$dir/handover.out" "a failed notify must call the handover off"
  sleep 3
  kill -0 "$pid" 2>/dev/null || fail "every refused or called-off handover must leave the helm running"
  assert_grep "status=aborted" "$home/state/.account-drain-handover" "the waiter must record that it was called off"
  cleanup_helms
  pass "fm-account-drain: refused and called-off handovers leave the helm running and say why"
}

test_handover_moves_the_helm_and_workers_survive() {
  local home dir_a dir_b pid_a pid_b standin worker start notes
  home=$(make_home handover)
  dir_a="$TMP_ROOT/handover-helm-a"
  dir_b="$TMP_ROOT/handover-helm-b"
  notes="$TMP_ROOT/handover-notes"
  start="$TMP_ROOT/handover-start"
  mkdir -p "$dir_b"
  # An in-flight worker: a live process and a task record whose Herdr pane the
  # fake herdr answers as alive.
  standin=$(fm_agent_standin "$TMP_ROOT/standin") || fail "no agent stand-in survives here"
  "$standin" 600 >/dev/null 2>&1 &
  worker=$!
  HELM_PIDS+=("$worker")
  printf 'window=sess:p-live\nkind=ship\nbackend=herdr\nworktree=%s\n' "$TMP_ROOT" > "$home/state/task-live.meta"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = pane ] && [ "${2:-}" = get ] && [ "${3:-}" = p-live ] && exit 0
exit 1
SH
  chmod +x "$FAKEBIN/herdr"
  cat > "$TMP_ROOT/notify" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$notes"
SH
  chmod +x "$TMP_ROOT/notify"
  # The start command: wait for the lock to read free or stale, as the fleet's
  # helm-autostart does, then start helm B on the ordinary store.
  cat > "$start" <<SH
#!/usr/bin/env bash
case "\$("$ROOT/bin/fm-lock.sh" status)" in
  "lock: free"|"lock: stale"*) ;;
  *) echo "start: lock still held" >&2; exit 1 ;;
esac
: > "$dir_b/requested"
SH
  chmod +x "$start"
  {
    printf 'handover_command=%s\n' "$start"
    printf 'notify_command=%s --subject helm\n' "$TMP_ROOT/notify"
  } >> "$home/config/account-drain"
  pid_a=$(start_helm "$home" "$STORE_ECO" "$dir_a")
  printf 'claude --model opus\n' > "$home/config/primary-harness"
  assert_contains "$(run_drain "$home" check)" "account-moved:" "the move must be announced"
  helm_handover "$dir_a"
  assert_grep "exit=0" "$dir_a/handover.out" "handover must arm: $(cat "$dir_a/handover.out")"
  assert_grep "handover armed" "$dir_a/handover.out" "handover must report it armed"
  assert_grep "Pick arjmad@gmail.com in the Claude app" "$notes" "the captain's line must name the account to pick"
  assert_grep "--subject helm Firstmate helm: moving from arjun@ecomills.com to arjmad@gmail.com" "$notes" \
    "the notify command must get its own words, then the message"
  for _ in $(seq 1 150); do
    kill -0 "$pid_a" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid_a" 2>/dev/null && fail "the waiter must end the old helm"
  mkdir -p "$dir_b"
  wait_for_file_line "$home/state/.account-drain-handover" "status=done" \
    || fail "the waiter must run the start command: $(cat "$home/state/account-drain-handover.log")"
  assert_present "$dir_b/requested" "the start command must run after the old helm released the lock"
  pid_b=$(start_helm "$home" ordinary "$dir_b")
  assert_grep "store=ordinary" "$home/state/.account-drain-session" "the fresh helm must record its own account"
  kill -0 "$worker" 2>/dev/null || fail "the in-flight worker must keep running through the handover"
  touch "$dir_b/start"
  wait_for_file_line "$dir_b/start.out" "^exit=" 900 || fail "the fresh helm's session start did not finish"
  assert_grep "endpoint: alive (backend=herdr window=sess:p-live)" "$dir_b/start.out" \
    "the fresh helm's session start must pick up the in-flight worker: $(head -c 3000 "$dir_b/start.out")"
  assert_equals "$pid_b" "$(head -n 1 "$home/state/.lock")" "the fresh helm must hold the session lock"
  assert_equals "" "$(run_drain "$home" check)" "the fresh helm runs on the launch line's account: no move"
  assert_equals 1 "$(grep -c 'Firstmate helm' "$notes")" "the captain must get exactly one line"
  cleanup_helms
  pass "fm-account-drain: handover ends the old helm, the start command brings a fresh one, and workers survive"
}

test_waiter_stands_down_when_away_mode_starts_in_the_grace() {
  local home dir pid
  home=$(make_home grace-away)
  dir="$TMP_ROOT/grace-away-helm"
  printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/grace-away-start"
  chmod +x "$TMP_ROOT/grace-away-start"
  printf 'handover_command=%s\n' "$TMP_ROOT/grace-away-start" >> "$home/config/account-drain"
  pid=$(HELM_GRACE=4 start_helm "$home" "$STORE_ECO" "$dir")
  printf 'claude\n' > "$home/config/primary-harness"
  helm_handover "$dir"
  assert_grep "handover armed" "$dir/handover.out" "handover must arm: $(cat "$dir/handover.out")"
  : > "$home/state/.afk-contract"
  wait_for_file_line "$home/state/.account-drain-handover" "status=aborted" 100 \
    || fail "the waiter must stand down when away mode starts during its grace: $(cat "$home/state/account-drain-handover.log")"
  kill -0 "$pid" 2>/dev/null || fail "away mode starting in the grace must leave the helm running"
  rm -f "$home/state/.afk-contract"
  assert_contains "$(run_drain "$home" check)" "account-moved:" "once away mode ends, the check must raise the move again"
  cleanup_helms
  pass "fm-account-drain: the waiter stands down when away mode starts during its grace"
}

test_handover_is_once_per_move() {
  local home dir pid
  home=$(make_home once)
  dir="$TMP_ROOT/once-helm"
  printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/once-start"
  chmod +x "$TMP_ROOT/once-start"
  printf 'handover_command=%s\nnotify_command=false\n' "$TMP_ROOT/once-start" >> "$home/config/account-drain"
  start_helm "$home" "$STORE_ECO" "$dir" >/dev/null
  printf 'claude\n' > "$home/config/primary-harness"
  pid=$(head -n 1 "$home/state/.lock")
  printf '%s %s\nstatus=done\n' "$pid" ordinary > "$home/state/.account-drain-handover"
  helm_handover "$dir"
  assert_grep "already handed over" "$dir/handover.out" "a second handover for one move must refuse"
  printf '%s %s\nstatus=aborted\n' "$pid" ordinary > "$home/state/.account-drain-handover"
  helm_handover "$dir"
  assert_no_grep "already handed over" "$dir/handover.out" "a called-off handover must be retryable"
  assert_grep "notify_command failed" "$dir/handover.out" "the retry must run the handover again"
  cleanup_helms
  pass "fm-account-drain: a move is handed over at most once, and a called-off one can be retried"
}

fm_test_run \
  test_unconfigured_home_is_inert \
  test_check_announces_each_move_once \
  test_check_holds_for_away_mode_and_a_disagreeing_drain_file \
  test_check_ignores_an_older_sessions_record \
  test_marker_reports_capability \
  test_both_low_answers \
  test_spawn_refuses_a_claude_ship_while_both_low \
  test_handover_refusals_leave_the_helm_running \
  test_handover_moves_the_helm_and_workers_survive \
  test_waiter_stands_down_when_away_mode_starts_in_the_grace \
  test_handover_is_once_per_move
