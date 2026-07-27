#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's explicit existing-worktree relaunch path.
#
# A relaunch must start the worker in the caller-selected worktree without
# asking treehouse to allocate another slot. The ordinary isolation assertion
# remains authoritative and must refuse both the primary checkout and paths
# that are not git worktree roots before any endpoint is created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-reuse-worktree)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for arg in "$@"; do printf '\x1f%s' "$arg"; done; printf '\n'; } >> "${FM_TMUX_LOG:?}"
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_path*) printf 'unexpected-pane-current-path-read\n'; exit 1 ;;
      *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-zsh}"; exit 0 ;;
      *pane_id*) printf '%%1\n'; exit 0 ;;
      *) printf 'firstmate\n'; exit 0 ;;
    esac
    ;;
  list-windows)
    # fm_backend_tmux_agent_state only trusts a foreground-command read once the
    # exact recorded window appears in its session inventory, so a case that
    # wants an endpoint probed must register its window name here.
    [ -z "${FM_FAKE_TMUX_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    exit 0
    ;;
  new-window) printf '@42\n'; exit 0 ;;
  set-window-option|send-keys|has-session|new-session|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse was executed directly\n' >> "${FM_TREEHOUSE_LOG:?}"
exit 99
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/existing worktree"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  PROJ_ABS=$(cd "$PROJ_DIR" && pwd)
  WT_REAL=$(cd "$WT_DIR" && pwd -P)
  TMUX_LOG="$CASE_DIR/tmux.log"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  # The foreground command the fake tmux reports, i.e. what the shared
  # fm_backend_agent_alive classifier sees for any endpoint this case probes.
  # A bare shell is the default, so every case starts from "confidently dead".
  PANE_COMMAND=zsh
  # Windows the fake tmux reports in its session inventory, i.e. the endpoints
  # that still EXIST. fm_backend_tmux_agent_state only trusts a foreground-command
  # read for a window it finds there, and reads an absent one as gone - which is
  # exactly what a stopped worker's stale metadata points at, so the dead cases
  # leave this empty and only the alive/ambiguous ones register a window.
  TMUX_WINDOWS=
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
}

run_spawn_argv() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_TMUX_LOG="$TMUX_LOG" FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    FM_FAKE_PANE_COMMAND="$PANE_COMMAND" \
    FM_FAKE_TMUX_WINDOWS="$TMUX_WINDOWS" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_spawn() {
  local id=$1 reuse_path=$2
  run_spawn_argv "$id" "$PROJ_DIR" claude --reuse-worktree "$reuse_path"
}

# register_live_tmux_window <owner-id>: report that owner's tmux window as still
# present in the fake session inventory, so its recorded endpoint is probed
# rather than read as gone.
register_live_tmux_window() {
  TMUX_WINDOWS="${TMUX_WINDOWS:+$TMUX_WINDOWS
}fm-$1"
}

# write_owner_meta <owner-id> <worktree>: a second task's metadata naming the
# same worktree, with a tmux endpoint whose liveness the fake pane command
# above decides (claude => alive, zsh => dead, node => unknown).
write_owner_meta() {
  local owner=$1 worktree=$2
  fm_write_meta "$HOME_DIR/state/$owner.meta" \
    "window=firstmate:fm-$owner" \
    "worktree=$worktree" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=default" \
    "yolo=off"
}

test_valid_reuse_skips_treehouse_and_records_worktree() {
  local id rec out status
  id=reuse-valid-z1
  rec=$(make_case valid "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "valid --reuse-worktree spawn should succeed"$'\n'"$out"
  assert_contains "$out" "worktree=$WT_REAL" \
    "success output did not print the reused worktree"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "metadata did not record the reused worktree"
  assert_grep "tasktmp=/tmp/fm-$id" "$HOME_DIR/state/$id.meta" \
    "metadata did not preserve the per-task temp root"
  assert_present "/tmp/fm-$id/gotmp" \
    "the reused-worktree path did not create the per-task Go temp root"
  assert_present "$WT_DIR/.claude/settings.local.json" \
    "the reused-worktree path did not install the turn-end hook"
  assert_contains "$(cat "$TMUX_LOG")" \
    "tmux"$'\x1f'"new-window"$'\x1f'"-dP"$'\x1f'"-F"$'\x1f'"#{window_id}"$'\x1f'"-t"$'\x1f'"firstmate:"$'\x1f'"-n"$'\x1f'"fm-$id"$'\x1f'"-c"$'\x1f'"$WT_REAL" \
    "the task endpoint was not created in the reused worktree"
  assert_not_contains "$(cat "$TMUX_LOG")" "treehouse get" \
    "--reuse-worktree still sent treehouse get to the worker shell"
  [ ! -s "$TREEHOUSE_LOG" ] || fail "--reuse-worktree executed treehouse directly"
  rm -rf "/tmp/fm-$id"
  pass "a valid reused worktree skips allocation and preserves downstream spawn state"
}

test_primary_checkout_is_refused() {
  local id rec out status
  id=reuse-primary-z2
  rec=$(make_case primary "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "the primary checkout must be refused"
  assert_contains "$out" "--reuse-worktree path did not yield an isolated worktree" \
    "primary-checkout refusal did not name the reused-worktree isolation failure"
  assert_contains "$out" "primary '$PROJ_ABS'" \
    "primary-checkout refusal did not identify the primary project path"
  [ ! -s "$TMUX_LOG" ] || fail "primary-checkout refusal created or inspected an endpoint"
  pass "the mandatory isolation assertion refuses the primary checkout"
}

test_non_worktree_path_is_refused() {
  local id rec plain out status
  id=reuse-plain-z3
  rec=$(make_case plain "$id")
  read_case "$rec"
  plain="$CASE_DIR/not-a-worktree"
  mkdir -p "$plain"

  out=$(run_spawn "$id" "$plain")
  status=$?
  expect_code 1 "$status" "a non-worktree directory must be refused"
  assert_contains "$out" "--reuse-worktree path did not yield an isolated worktree" \
    "non-worktree refusal did not name the reused-worktree validation failure"
  assert_contains "$out" "worktree root 'none'" \
    "non-worktree refusal did not explain that no git worktree root was found"
  [ ! -s "$TMUX_LOG" ] || fail "non-worktree refusal created or inspected an endpoint"
  pass "a non-worktree directory is refused before endpoint creation"
}

test_missing_path_is_refused_clearly() {
  local id rec missing out status
  id=reuse-missing-z4
  rec=$(make_case missing "$id")
  read_case "$rec"
  missing="$CASE_DIR/does-not-exist"

  out=$(run_spawn "$id" "$missing")
  status=$?
  expect_code 1 "$status" "a missing reused-worktree path must be refused"
  assert_contains "$out" "--reuse-worktree path does not exist or is not a directory: $missing" \
    "missing-path refusal was not explicit"
  [ ! -s "$TMUX_LOG" ] || fail "missing-path refusal created or inspected an endpoint"
  pass "a missing reused-worktree path fails clearly before endpoint creation"
}

test_foreign_repository_worktree_is_refused() {
  local id rec other_repo other_wt out status
  id=reuse-foreign-z5
  rec=$(make_case foreign "$id")
  read_case "$rec"
  other_repo="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other worktree"
  fm_git_worktree "$other_repo" "$other_wt" "fm/other"

  out=$(run_spawn "$id" "$other_wt")
  status=$?
  expect_code 1 "$status" "a worktree of an unrelated repository must be refused"
  assert_contains "$out" "--reuse-worktree path is not a worktree of this project" \
    "foreign-repository refusal did not name the membership failure"
  assert_contains "$out" "primary '$PROJ_ABS'" \
    "foreign-repository refusal did not identify the primary project path"
  [ ! -s "$TMUX_LOG" ] || fail "foreign-repository refusal created or inspected an endpoint"
  pass "a worktree belonging to another repository is refused before endpoint creation"
}

test_worktree_owned_by_live_task_is_refused() {
  local id rec out status
  id=reuse-live-owner-z6
  rec=$(make_case live-owner "$id")
  read_case "$rec"
  write_owner_meta owner-live-z6 "$WT_REAL"
  register_live_tmux_window owner-live-z6
  PANE_COMMAND=claude

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "a worktree owned by a live task must be refused"
  assert_contains "$out" "is already recorded by task owner-live-z6" \
    "live-owner refusal did not name the owning task"
  assert_contains "$out" "endpoint reported as alive" \
    "live-owner refusal did not report the owning endpoint as alive"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "live-owner refusal created a task endpoint"
  pass "a worktree recorded by a task with a live endpoint is refused"
}

test_worktree_owned_by_unreadable_task_is_refused() {
  local id rec out status
  id=reuse-unknown-owner-z7
  rec=$(make_case unknown-owner "$id")
  read_case "$rec"
  write_owner_meta owner-unknown-z7 "$WT_REAL"
  register_live_tmux_window owner-unknown-z7
  PANE_COMMAND=node

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "an unreadable owning endpoint must not license sharing the worktree"
  assert_contains "$out" "is already recorded by task owner-unknown-z7" \
    "unknown-owner refusal did not name the owning task"
  assert_contains "$out" "endpoint reported as unknown" \
    "unknown-owner refusal did not report the owning endpoint as unknown"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "unknown-owner refusal created a task endpoint"
  pass "an inconclusive owning-endpoint reading refuses rather than sharing the worktree"
}

test_worktree_owned_by_dead_task_is_reclaimed() {
  local id rec out status
  id=reuse-dead-owner-z8
  rec=$(make_case dead-owner "$id")
  read_case "$rec"
  write_owner_meta owner-dead-z8 "$WT_REAL"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a dead owning endpoint must release the worktree"$'\n'"$out"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "the reclaimed worktree was not recorded for the relaunched task"
  rm -rf "/tmp/fm-$id"
  pass "stale metadata over a dead endpoint still permits the relaunch"
}

test_own_stale_metadata_does_not_block_relaunch() {
  local id rec out status
  id=reuse-self-stale-z9
  rec=$(make_case self-stale "$id")
  read_case "$rec"
  write_owner_meta "$id" "$WT_REAL"
  PANE_COMMAND=node

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a task's own prior metadata must not block its relaunch"$'\n'"$out"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "the relaunched task did not record its own worktree"
  rm -rf "/tmp/fm-$id"
  pass "the exclusivity scan skips the relaunching task's own metadata"
}

test_batch_dispatch_is_refused() {
  local id rec out status
  id=reuse-batch-za1
  rec=$(make_case batch "$id")
  read_case "$rec"

  out=$(run_spawn_argv "$id=$PROJ_DIR" claude --reuse-worktree "$WT_DIR")
  status=$?
  expect_code 1 "$status" "batch dispatch must refuse --reuse-worktree"
  assert_contains "$out" "--reuse-worktree cannot be used with batch dispatch" \
    "batch refusal did not name the batch mutual exclusion"
  [ ! -s "$TMUX_LOG" ] || fail "batch refusal created or inspected an endpoint"
  pass "batch dispatch refuses one shared reused worktree"
}

test_secondmate_is_refused() {
  local id rec out status
  id=reuse-secondmate-za2
  rec=$(make_case secondmate "$id")
  read_case "$rec"

  out=$(run_spawn_argv "$id" --secondmate --reuse-worktree "$WT_DIR")
  status=$?
  expect_code 1 "$status" "--secondmate must refuse --reuse-worktree"
  assert_contains "$out" "--reuse-worktree cannot be combined with --secondmate" \
    "secondmate refusal did not name the secondmate mutual exclusion"
  [ ! -s "$TMUX_LOG" ] || fail "secondmate refusal created or inspected an endpoint"
  pass "a secondmate spawn refuses a reused worktree and stays in its provisioned home"
}

test_orca_backend_is_refused() {
  local id rec out status
  id=reuse-orca-za3
  rec=$(make_case orca "$id")
  read_case "$rec"

  out=$(run_spawn_argv "$id" "$PROJ_DIR" claude --backend orca --reuse-worktree "$WT_DIR")
  status=$?
  expect_code 1 "$status" "backend=orca must refuse --reuse-worktree"
  assert_contains "$out" "--reuse-worktree cannot be combined with backend=orca" \
    "orca refusal did not name the orca mutual exclusion"
  [ ! -s "$TMUX_LOG" ] || fail "orca refusal created or inspected an endpoint"
  pass "backend=orca refuses a reused worktree because it owns worktree creation"
}

test_valid_reuse_skips_treehouse_and_records_worktree
test_primary_checkout_is_refused
test_non_worktree_path_is_refused
test_missing_path_is_refused_clearly
test_foreign_repository_worktree_is_refused
test_worktree_owned_by_live_task_is_refused
test_worktree_owned_by_unreadable_task_is_refused
test_worktree_owned_by_dead_task_is_reclaimed
test_own_stale_metadata_does_not_block_relaunch
test_batch_dispatch_is_refused
test_secondmate_is_refused
test_orca_backend_is_refused

echo "# all fm-spawn-reuse-worktree tests passed"
