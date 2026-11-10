#!/usr/bin/env bash
# Behavior tests for bin/fm-procevent.sh retire-quiet-boards and the reconcile
# cadence that runs it: a Lavish board firstmate owns or adopted is retired
# after a quiet period with no round, or once an adopted board's backlog rows
# have all closed, while a worker-owned board and a board its task hosts again
# are kept, and a retired board's unread rounds stay captured.
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

archive_at() {  # <home> <archive path relative to the home>
  sed "s#^archive = .*#archive = \"$2\"#" "$1/.tasks.toml" > "$1/tasks.toml.new" || fail "cannot point the archive at $2"
  mv "$1/tasks.toml.new" "$1/.tasks.toml" || fail "cannot point the archive at $2"
}

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
  board "$home" lavish-relaunching "$OLD" 'adopted_from=scout-relaunching'
  printf 'working [at=1]: relaunched\n' > "$home/state/scout-relaunching.status"
  board "$home" lavish-rebuilt "$OLD"
  mkdir -p "$home/state/decision-bindings"
  printf 'schema=fm-decision-binding.v1\norigin=(any)\n' > "$home/state/decision-bindings/lavish-rebuilt.origin"
  fm_touch_epoch "$RECENT" "$home/state/decision-bindings/lavish-rebuilt.origin"

  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"

  registered "$home" lavish-quiet && fail "a board quiet for 15 days stayed registered"
  assert_contains "$out" "board-retired: lavish-quiet reason=quiet quiet_days=15" "the quiet board's retirement line"
  registered "$home" lavish-only-silent && fail "a board whose only recent round was silent stayed registered"
  assert_contains "$out" "board-retired: lavish-only-silent reason=quiet" "a silent round does not count as a round"
  registered "$home" lavish-fresh || fail "a board published two days ago was retired"
  registered "$home" lavish-answered || fail "a board answered two days ago was retired"
  registered "$home" lavish-unread && fail "a board whose only round is an unread one 15 days old stayed registered"
  [ -f "$home/state/procevent-inbox/lavish-unread.1.result" ] && [ ! -e "$home/state/procevent-inbox/lavish-unread.1.handled" ] \
    || fail "retiring a board touched its unread round"
  registered "$home" lavish-worker || fail "a worker-owned board was retired"
  registered "$home" lavish-rehosted || fail "an adopted board whose task is live again was retired"
  registered "$home" lavish-relaunching || fail "an adopted board whose task is being relaunched was retired"
  registered "$home" lavish-rebuilt || fail "a board whose binding was written again two days ago was retired"
  assert_grep "board-retired: lavish-quiet reason=quiet" "$home/state/procevent/board-retirements.log" "the durable retirement log"
  [ "$(printf '%s\n' "$out" | grep -c '^board-retired: ')" = 3 ] || fail "expected exactly three retirements, got: $out"

  FM_PROCEVENT_BOARD_QUIET_SECONDS=$DAY pe "$home" retire-quiet-boards >/dev/null \
    || fail "a one-day quiet setting failed"
  registered "$home" lavish-fresh && fail "the quiet period setting was not honored"
  rc=0
  FM_PROCEVENT_BOARD_QUIET_SECONDS=2w pe "$home" retire-quiet-boards >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an unusable quiet setting"
  pass "quiet boards retire keeping their unread rounds, and hosted, rebuilt, answered, or worker-owned boards stay"
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
  board "$home" lavish-long "$RECENT" 'adopted_from=scout-d'
  axi "$home" add call-d1 "closed call" --body "Board handed over from scout-d at 2026-11-01T00:00:00Z."
  axi "$home" "done" call-d1
  axi "$home" add call-d2 "long open call" --body "$(printf 'context %.0s' $(seq 1 120))
Board handed over from scout-d at 2026-11-01T00:00:00Z."

  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-closed || fail "an adopted board with open rows was retired"

  axi "$home" "done" call-a1
  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-closed || fail "an adopted board was retired while one of its rows is open"

  axi "$home" "done" call-a2
  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-closed && fail "an adopted board whose rows all closed stayed registered"
  assert_contains "$out" "board-retired: lavish-closed reason=row-closed quiet_days=2 adopted_from=scout-a" "the row-closed retirement line"
  registered "$home" lavish-open || fail "an adopted board with an open row was retired"
  registered "$home" lavish-prefix || fail "a task id that prefixes another task's id matched its rows"
  registered "$home" lavish-unlinked || fail "an adopted board with no linked row was retired before its quiet period"
  registered "$home" lavish-long || fail "an open row whose long body hides its handover line from list was missed"
  pass "an adopted board retires once every backlog row carrying it has closed"
}

# Done retention moves a closed row out of the backlog into the configured
# archive, so a carrying row the sweep must see can live there alone.
test_adopted_board_retires_when_its_rows_are_archived() {
  local home out unreadable
  home=$(new_home archived)
  board "$home" lavish-archived "$RECENT" 'adopted_from=scout-e'
  axi "$home" add call-e1 "archived call" --body "Board handed over from scout-e at 2026-11-01T00:00:00Z."
  board "$home" lavish-half "$RECENT" 'adopted_from=scout-f'
  axi "$home" add call-f1 "archived half" --body "Board handed over from scout-f at 2026-11-01T00:00:00Z."
  axi "$home" add call-f2 "open half" --body "Board handed over from scout-f at 2026-11-01T00:00:00Z."
  board "$home" lavish-nowhere "$RECENT" 'adopted_from=scout-g'
  axi "$home" "done" call-e1 --keep 0
  axi "$home" "done" call-f1 --keep 0
  assert_grep "Board handed over from scout-e at" "$home/data/done-archive.md" "the archived carrying row"
  assert_no_grep "scout-e" "$home/data/backlog.md" "the live backlog after retention"

  # A closed live row beside an archive that cannot be read is not the whole
  # picture. A directory where the archive should be is unreadable even to root.
  unreadable=$(new_home archive-unreadable)
  board "$unreadable" lavish-archived "$RECENT" 'adopted_from=scout-e'
  axi "$unreadable" add call-e2 "live closed call" --body "Board handed over from scout-e at 2026-11-01T00:00:00Z."
  axi "$unreadable" "done" call-e2
  mkdir "$unreadable/data/done-archive.md"

  out=$(pe "$home" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-archived && fail "an adopted board whose only carrying row is archived stayed registered"
  assert_contains "$out" "board-retired: lavish-archived reason=row-closed quiet_days=2 adopted_from=scout-e" "the archived row's retirement line"
  registered "$home" lavish-half || fail "an adopted board with an archived row and an open live row was retired"
  registered "$home" lavish-nowhere || fail "an adopted board with no carrying row in the backlog or archive was retired early"

  out=$(pe "$unreadable" retire-quiet-boards) || fail "retire-quiet-boards failed with an unreadable archive: $out"
  registered "$unreadable" lavish-archived || fail "an unreadable archive retired an adopted board early"
  rmdir "$unreadable/data/done-archive.md"
  # An archive whose directory cannot be searched cannot be told absent: a
  # regular file as its parent blocks even root, and a mode-000 one blocks others.
  : > "$unreadable/data/plain"
  archive_at "$unreadable" data/plain/done-archive.md
  out=$(pe "$unreadable" retire-quiet-boards) || fail "retire-quiet-boards failed with a file as the archive's parent: $out"
  registered "$unreadable" lavish-archived || fail "an archive under a regular file retired an adopted board early"
  mkdir "$unreadable/data/locked"
  cp "$home/data/done-archive.md" "$unreadable/data/locked/done-archive.md"
  archive_at "$unreadable" data/locked/done-archive.md
  chmod 000 "$unreadable/data/locked"
  if [ -x "$unreadable/data/locked" ]; then
    echo "skip: a mode-000 archive directory is still searchable here (root)"
  else
    out=$(pe "$unreadable" retire-quiet-boards) || fail "retire-quiet-boards failed with an unsearchable archive directory: $out"
    registered "$unreadable" lavish-archived || fail "an archive in an unsearchable directory retired an adopted board early"
  fi
  chmod 700 "$unreadable/data/locked"
  fm_test_tasks_toml "$unreadable/.tasks.toml"
  cp "$home/data/done-archive.md" "$unreadable/data/done-archive.md"
  out=$(pe "$unreadable" retire-quiet-boards) || fail "retire-quiet-boards failed: $out"
  assert_contains "$out" "board-retired: lavish-archived reason=row-closed" "the same board once its archive reads"

  # An archive configured into a directory retention has not created yet is
  # absent, so the closed live row alone retires the board.
  board "$unreadable" lavish-archived "$RECENT" 'adopted_from=scout-e'
  archive_at "$unreadable" data/later/done-archive.md
  out=$(pe "$unreadable" retire-quiet-boards) || fail "retire-quiet-boards failed with a missing archive directory: $out"
  assert_contains "$out" "board-retired: lavish-archived reason=row-closed" "a board whose archive directory does not exist yet"
  pass "an adopted board retires once its carrying rows are closed in the backlog or the archive"
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

test_conditional_retire_matches_owned_boards() {
  local home rc
  home=$(new_home owned-match)
  board "$home" lavish-adopted "$RECENT" 'adopted_from=scout-a'
  rc=0
  pe "$home" retire lavish-adopted --if-matches lavish -- "$BLOCKER" "$home/never-lavish-adopted" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a plain match against an adopted board"
  rc=0
  pe "$home" retire lavish-adopted --if-matches lavish --adopted-from scout-b -- "$BLOCKER" "$home/never-lavish-adopted" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an adopted match naming another task"
  registered "$home" lavish-adopted || fail "a mismatched conditional retire dropped the adopted board"
  pe "$home" retire lavish-adopted --if-matches lavish --adopted-from scout-a -- "$BLOCKER" "$home/never-lavish-adopted" >/dev/null \
    || fail "an exact adopted match did not retire the adopted board"
  registered "$home" lavish-adopted && fail "an exact adopted match left the board registered"

  board "$home" lavish-worker "$RECENT" 'kind=task-owned
owner_task=worker-a'
  rc=0
  pe "$home" retire lavish-worker --if-matches lavish --adopted-from worker-a -- "$BLOCKER" "$home/never-lavish-worker" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an adopted match against a task-owned board"
  rc=0
  pe "$home" retire lavish-worker --if-matches lavish --owner-task worker-b -- "$BLOCKER" "$home/never-lavish-worker" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a task-owned match naming another task"
  registered "$home" lavish-worker || fail "a mismatched conditional retire dropped the task-owned board"
  pe "$home" retire lavish-worker --if-matches lavish --owner-task worker-a -- "$BLOCKER" "$home/never-lavish-worker" >/dev/null \
    || fail "an exact task-owned match did not retire the task-owned board"
  registered "$home" lavish-worker && fail "an exact task-owned match left the board registered"
  pass "a conditional retire matches adopted and task-owned boards exactly"
}

# A board re-armed after the sweep read it must survive the sweep. The sweep
# calls its own bin directory's fm-procevent.sh to retire, so a copy of bin/
# whose fm-procevent.sh replaces the registration just before passing a retire
# through lands the re-arm inside that window.
test_sweep_leaves_a_board_rearmed_mid_sweep() {
  local home bin out reg
  home=$(new_home rearm)
  bin="$TMP_ROOT/rearm-bin"
  cp -R "$ROOT/bin" "$bin"
  mv "$bin/fm-procevent.sh" "$bin/fm-procevent-real.sh"
  cat > "$bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "${1-}" = retire ] && [ -f "$FM_HOME/rearm/${2-}.source" ]; then
  mv -f -- "$FM_HOME/rearm/$2.source" "$FM_HOME/state/procevent/$2.source"
fi
exec "$dir/fm-procevent-real.sh" "$@"
SH
  chmod +x "$bin/fm-procevent.sh"
  reg="$home/state/procevent"
  mkdir -p "$home/rearm"
  board "$home" lavish-adopted "$OLD" 'adopted_from=scout-a'
  board "$home" lavish-plain "$OLD"
  # The re-armed records: the same boards listening on a new link.
  for id in lavish-adopted lavish-plain; do
    sed 's/never-/moved-/' "$reg/$id.source" > "$home/rearm/$id.source"
    chmod 600 "$home/rearm/$id.source"
  done

  out=$(FM_HOME="$home" "$bin/fm-procevent-real.sh" retire-quiet-boards 2>&1) \
    || fail "retire-quiet-boards failed: $out"
  registered "$home" lavish-adopted || fail "the sweep retired an adopted board re-armed after its read"
  assert_grep "moved-lavish-adopted" "$reg/lavish-adopted.source" "the re-armed adopted board's registration"
  registered "$home" lavish-plain || fail "the sweep retired a plain board re-armed after its read"
  assert_grep "moved-lavish-plain" "$reg/lavish-plain.source" "the re-armed plain board's registration"
  assert_not_contains "$out" "board-retired:" "a sweep over re-armed boards"
  pass "the sweep leaves a board re-armed between its read and its retire"
}

test_quiet_rule_and_kept_boards
test_adopted_board_retires_when_its_rows_close
test_adopted_board_retires_when_its_rows_are_archived
test_conditional_retire_matches_owned_boards
test_sweep_leaves_a_board_rearmed_mid_sweep
test_reconcile_runs_the_sweep_on_its_cadence
