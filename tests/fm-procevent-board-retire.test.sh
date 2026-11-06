#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent.sh retire-quiet-boards and the reconcile
# cadence that runs it: a Lavish board firstmate owns or adopted is retired
# after a quiet period with no round, or once an adopted board's backlog rows
# have all closed, while a worker-owned board, a board its task hosts again, and
# a board with an unread round are kept.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-board-retire)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
unset FM_PROCEVENT_BOARD_QUIET_SECONDS FM_PROCEVENT_BOARD_SWEEP_SECONDS

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

DAY=86400
NOW=$(date +%s)
OLD=$((NOW - 15 * DAY))
RECENT=$((NOW - 2 * DAY))

# A listener that never returns on its own: a board this suite keeps registered
# may be launched by reconcile, and the home is reaped on exit.
BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$1" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
SH
chmod +x "$BLOCKER"

new_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state/procevent" "$home/state/procevent-inbox" "$home/config"
  chmod 700 "$home/state" "$home/state/procevent" "$home/state/procevent-inbox"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fm_test_track_procevent_home "$home"
  printf '%s\n' "$home"
}

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null 2>&1 \
    || fail "tasks-axi $* failed in $home"
}

# Persisted registration fixtures in the record format bin/fm-procevent-lib.sh
# publishes; <extra> carries the owner line of a worker-owned or adopted board.
board() {  # <home> <source-id> <published-epoch> [extra-line]
  local home=$1 id=$2 at=$3 extra=${4-} rec="$1/state/procevent/$2.source"
  {
    printf 'adapter=lavish\n'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf 'argc=2\nargv:\n%s\n%s\n' "$BLOCKER" "$home/never-$id"
  } > "$rec"
  chmod 600 "$rec"
  fm_touch_epoch "$at" "$rec"
}

# One captured round of a board, acknowledged unless asked otherwise.
round() {  # <home> <source-id> <sequence> <epoch> <silent|said> [unread]
  local result="$1/state/procevent-inbox/$2.$3.result"
  case "$5" in
    silent) printf 'session:\n  file: /a.html\n  status: browser_disconnected\n' > "$result" ;;
    said) printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","ship it","","message",""\n' > "$result" ;;
  esac
  fm_touch_epoch "$4" "$result"
  [ "${6-}" = unread ] || : > "${result%.result}.handled"
}

registered() { [ -f "$1/state/procevent/$2.source" ]; }

test_quiet_rule_and_kept_boards() {
  local home out rc
  home=$(new_home quiet)
  board "$home" lavish-quiet "$OLD"
  board "$home" lavish-fresh "$RECENT"
  board "$home" lavish-answered "$OLD"
  round "$home" lavish-answered 1 "$RECENT" said
  board "$home" lavish-only-silent "$OLD"
  round "$home" lavish-only-silent 1 "$RECENT" silent
  board "$home" lavish-unread "$OLD"
  round "$home" lavish-unread 1 "$OLD" said unread
  board "$home" lavish-worker "$OLD" 'kind=task-owned
owner_task=worker-a'
  board "$home" lavish-rehosted "$OLD" 'adopted_from=scout-live'
  printf 'window=x\n' > "$home/state/scout-live.meta"

  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"

  registered "$home" lavish-quiet && fail "a board quiet for 15 days stayed registered"
  assert_contains "$out" "board-retired: lavish-quiet reason=quiet quiet_days=15" "the quiet board's retirement line"
  registered "$home" lavish-only-silent && fail "a board whose only recent round was silent stayed registered"
  assert_contains "$out" "board-retired: lavish-only-silent reason=quiet" "a silent round does not count as a round"
  registered "$home" lavish-fresh || fail "a board published two days ago was retired"
  registered "$home" lavish-answered || fail "a board answered two days ago was retired"
  registered "$home" lavish-unread || fail "a board with an unread round was retired"
  registered "$home" lavish-worker || fail "a worker-owned board was retired"
  registered "$home" lavish-rehosted || fail "an adopted board whose task is live again was retired"
  assert_grep "board-retired: lavish-quiet reason=quiet" "$home/state/procevent/board-retirements.log" "the durable retirement log"
  [ "$(printf '%s\n' "$out" | grep -c '^board-retired: ')" = 2 ] || fail "expected exactly two retirements, got: $out"

  FM_PROCEVENT_BOARD_QUIET_SECONDS=$DAY pe "$home" retire-quiet-boards >/dev/null \
    || fail "a one-day quiet setting failed"
  registered "$home" lavish-fresh && fail "the quiet period setting was not honored"
  rc=0
  FM_PROCEVENT_BOARD_QUIET_SECONDS=2w pe "$home" retire-quiet-boards >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an unusable quiet setting"
  pass "quiet boards retire and hosted, answered, unread, or worker-owned boards stay"
}

test_adopted_board_retires_when_its_rows_close() {
  local home out
  home=$(new_home adopted)
  board "$home" lavish-closed "$RECENT" 'adopted_from=scout-a'
  axi "$home" add call-a1 "first call" --body "Captain hold board: http://x/1

Board handed over from scout-a at 2026-11-01T00:00:00Z."
  axi "$home" add call-a2 "second call" --body "Board handed over from scout-a at 2026-11-01T00:00:00Z."
  board "$home" lavish-open "$RECENT" 'adopted_from=scout-b'
  axi "$home" add call-b1 "open call" --body "Board handed over from scout-b at 2026-11-01T00:00:00Z."
  board "$home" lavish-prefix "$RECENT" 'adopted_from=scout'
  board "$home" lavish-unlinked "$RECENT" 'adopted_from=scout-c'

  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-closed || fail "an adopted board with open rows was retired"

  axi "$home" done call-a1
  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-closed || fail "an adopted board was retired while one of its rows is open"

  axi "$home" done call-a2
  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-closed && fail "an adopted board whose rows all closed stayed registered"
  assert_contains "$out" "board-retired: lavish-closed reason=row-closed quiet_days=2 adopted_from=scout-a" "the row-closed retirement line"
  registered "$home" lavish-open || fail "an adopted board with an open row was retired"
  registered "$home" lavish-prefix || fail "a task id that prefixes another task's id matched its rows"
  registered "$home" lavish-unlinked || fail "an adopted board with no linked row was retired before its quiet period"
  pass "an adopted board retires once every backlog row carrying it has closed"
}

test_reconcile_runs_the_sweep_on_its_cadence() {
  local home out
  home=$(new_home cadence)
  board "$home" lavish-first "$OLD"
  out=$(pe "$home" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "board-retired: lavish-first reason=quiet" "reconcile's first sweep"
  assert_contains "$out" "stopped=1" "a retired board counts as stopped"
  registered "$home" lavish-first && fail "reconcile left the quiet board registered"

  board "$home" lavish-second "$OLD"
  out=$(pe "$home" reconcile) || fail "reconcile failed: $out"
  assert_not_contains "$out" "board-retired:" "a sweep inside the cadence"
  registered "$home" lavish-second || fail "reconcile swept again inside its cadence"

  out=$(FM_PROCEVENT_BOARD_SWEEP_SECONDS=x FM_PROCEVENT_BOARD_QUIET_SECONDS=1 pe "$home" reconcile) \
    || fail "reconcile failed with an unusable sweep setting: $out"
  registered "$home" lavish-second || fail "an unusable sweep setting still swept"

  out=$(FM_PROCEVENT_BOARD_SWEEP_SECONDS=0 pe "$home" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "board-retired: lavish-second reason=quiet" "a zero cadence sweeps every cycle"
  registered "$home" lavish-second && fail "reconcile left the second quiet board registered"
  pass "reconcile sweeps quiet boards at most once per cadence"
}

test_quiet_rule_and_kept_boards
test_adopted_board_retires_when_its_rows_close
test_reconcile_runs_the_sweep_on_its_cadence
