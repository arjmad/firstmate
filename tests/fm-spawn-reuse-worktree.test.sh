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
      *pane_id*) printf '%%1\n'; exit 0 ;;
      *) printf 'firstmate\n'; exit 0 ;;
    esac
    ;;
  list-windows) exit 0 ;;
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
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
}

run_spawn() {
  local id=$1 reuse_path=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_TMUX_LOG="$TMUX_LOG" FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" claude --reuse-worktree "$reuse_path" 2>&1
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

test_valid_reuse_skips_treehouse_and_records_worktree
test_primary_checkout_is_refused
test_non_worktree_path_is_refused
test_missing_path_is_refused_clearly

echo "# all fm-spawn-reuse-worktree tests passed"
