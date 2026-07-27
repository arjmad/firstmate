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
  # A herdr CLI that logs every invocation, so a case can assert both what the
  # owner probe read and that it never reached for `herdr server`. `status --json`
  # reports FM_FAKE_HERDR_MODE as the real client does - a client with no server
  # bound still answers, with running:false, which is why server-down is a
  # positive reading rather than a failed one. Pane and agent reads answer
  # according to FM_FAKE_HERDR_PANE_ERROR / FM_FAKE_HERDR_AGENT_STATUS, writing
  # any error body to stderr and exiting non-zero exactly as herdr 0.7.1 does.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'herdr'; for arg in "$@"; do printf '\x1f%s' "$arg"; done; printf '\n'; } >> "${FM_HERDR_LOG:?}"
mode=${FM_FAKE_HERDR_MODE:-down}
case "${1:-}:${2:-}" in
  status:*)
    case "$mode" in
      up) printf '{"server":{"running":true},"client":{"protocol":99,"version":"fake"}}\n' ;;
      garbled) printf '{"client":{"protocol":99,"version":"fake"}}\n' ;;
      *) printf '{"server":{"running":false},"client":{"protocol":99,"version":"fake"}}\n' ;;
    esac
    exit 0
    ;;
esac
if [ "$mode" != up ]; then
  printf '{"error":{"code":"connection_refused","message":"no herdr server"}}\n' >&2
  exit 1
fi
case "${1:-}:${2:-}" in
  pane:get)
    if [ -n "${FM_FAKE_HERDR_PANE_ERROR:-}" ]; then
      printf '{"error":{"code":"%s"}}\n' "$FM_FAKE_HERDR_PANE_ERROR" >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    exit 0
    ;;
  agent:get) printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FM_FAKE_HERDR_AGENT_STATUS:-unrecognized}"; exit 0 ;;
esac
printf '{"result":{}}\n'
exit 0
SH
  chmod +x "$fakebin/herdr"
  # A zellij CLI covering only the two read-only calls the presence check makes:
  # the session listing fm_backend_zellij_session_exists greps, and the pane
  # listing fm_backend_zellij_pane_exists filters. FM_FAKE_ZELLIJ_SESSION empty
  # means no session is up at all.
  cat > "$fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'zellij'; for arg in "$@"; do printf '\x1f%s' "$arg"; done; printf '\n'; } >> "${FM_ZELLIJ_LOG:?}"
case "$*" in
  *list-sessions*)
    [ -n "${FM_FAKE_ZELLIJ_SESSION:-}" ] || exit 1
    printf '%s\n' "$FM_FAKE_ZELLIJ_SESSION"
    exit 0
    ;;
  *list-panes*)
    printf '[{"id":%s,"tab_id":1,"is_plugin":false}]\n' "${FM_FAKE_ZELLIJ_PANE:-3}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/zellij"
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
  HERDR_LOG="$CASE_DIR/herdr.log"
  ZELLIJ_LOG="$CASE_DIR/zellij.log"
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
  HERDR_MODE=down
  HERDR_AGENT_STATUS=unrecognized
  HERDR_PANE_ERROR=
  ZELLIJ_SESSION=zsess
  ZELLIJ_PANE=3
  SPAWN_PATH="$FAKEBIN_DIR:$PATH"
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
  : > "$HERDR_LOG"
  : > "$ZELLIJ_LOG"
}

run_spawn_argv() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_TMUX_LOG="$TMUX_LOG" FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
    FM_HERDR_LOG="$HERDR_LOG" FM_ZELLIJ_LOG="$ZELLIJ_LOG" \
    FM_FAKE_PANE_COMMAND="$PANE_COMMAND" \
    FM_FAKE_TMUX_WINDOWS="$TMUX_WINDOWS" \
    FM_FAKE_HERDR_MODE="$HERDR_MODE" \
    FM_FAKE_HERDR_AGENT_STATUS="$HERDR_AGENT_STATUS" \
    FM_FAKE_HERDR_PANE_ERROR="$HERDR_PANE_ERROR" \
    FM_FAKE_ZELLIJ_SESSION="$ZELLIJ_SESSION" \
    FM_FAKE_ZELLIJ_PANE="$ZELLIJ_PANE" \
    PATH="$SPAWN_PATH" \
    "$SPAWN" "$@" 2>&1
}

# hide_tool_from_spawn_path <tool>: drop the case's own stub for <tool> and strip
# every PATH entry that still provides it, so the spawn genuinely cannot find it
# however the host machine is set up.
hide_tool_from_spawn_path() {
  local tool=$1 dir kept=
  rm -f "$FAKEBIN_DIR/$tool"
  local IFS=:
  for dir in $SPAWN_PATH; do
    [ -n "$dir" ] || continue
    [ -x "$dir/$tool" ] && continue
    kept="${kept:+$kept:}$dir"
  done
  SPAWN_PATH=$kept
  command -v "$tool" >/dev/null 2>&1 && PATH="$SPAWN_PATH" command -v "$tool" >/dev/null 2>&1 && \
    fail "hide_tool_from_spawn_path left $tool reachable on the spawn PATH"
  return 0
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

# write_herdr_owner_meta <owner-id> <worktree>: an owner recorded against the
# herdr backend while the current spawn stays on tmux - the cross-backend shape
# that must never boot a herdr server just to read the owner.
write_herdr_owner_meta() {
  local owner=$1 worktree=$2
  fm_write_meta "$HOME_DIR/state/$owner.meta" \
    "window=fmtest:%7" \
    "backend=herdr" \
    "worktree=$worktree" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=default" \
    "yolo=off"
}

# write_zellij_owner_meta <owner-id> <worktree>: an owner on a backend whose
# adapter has no verified agent-liveness probe, so a still-present endpoint can
# only ever read as unknown.
write_zellij_owner_meta() {
  local owner=$1 worktree=$2
  fm_write_meta "$HOME_DIR/state/$owner.meta" \
    "window=zsess:3" \
    "backend=zellij" \
    "worktree=$worktree" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=default" \
    "yolo=off"
}

# write_endpointless_owner_meta <owner-id> <worktree>: a truncated or hand-edited
# meta that names the worktree but records no endpoint at all.
write_endpointless_owner_meta() {
  local owner=$1 worktree=$2
  fm_write_meta "$HOME_DIR/state/$owner.meta" \
    "worktree=$worktree" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship"
}

# assert_herdr_probe_stayed_passive [expected-pane-reads]: the probe must have
# asked herdr whether its server is running, must never have reached for
# `herdr server`, and must have read the pane exactly as many times as claimed
# (0 when the runtime answered down, 1 otherwise - never twice for one owner).
assert_herdr_probe_stayed_passive() {
  local want_pane_reads=${1:-1} log reads
  log=$(cat "$HERDR_LOG")
  assert_contains "$log" "herdr"$'\x1f'"status"$'\x1f'"--json" \
    "the owner probe never asked herdr whether its server was running"
  assert_not_contains "$log" "herdr"$'\x1f'"server" \
    "the owner liveness probe started or polled a herdr server"
  reads=$(grep -c -F "herdr"$'\x1f'"pane"$'\x1f'"get" "$HERDR_LOG" || true)
  [ "$reads" -eq "$want_pane_reads" ] || \
    fail "expected $want_pane_reads herdr pane read(s), got $reads"$'\n'"--- herdr log ---"$'\n'"$log"
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

test_same_task_relaunch_over_live_endpoint_is_refused() {
  local id rec out status
  id=reuse-self-live-z9
  rec=$(make_case self-live "$id")
  read_case "$rec"
  write_owner_meta "$id" "$WT_REAL"
  register_live_tmux_window "$id"
  PANE_COMMAND=claude

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "relaunching a task over its own live endpoint must be refused"
  assert_contains "$out" "is already recorded by this task's own prior launch" \
    "self-relaunch refusal did not identify the task's own prior launch"
  assert_contains "$out" "endpoint reported as alive" \
    "self-relaunch refusal did not report the prior endpoint as alive"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "self-relaunch refusal created a second endpoint over the live one"
  assert_grep "window=firstmate:fm-$id" "$HOME_DIR/state/$id.meta" \
    "the refused self-relaunch overwrote the live endpoint in metadata"
  pass "a live worker is never replaced by a relaunch into its own worktree"
}

test_same_task_relaunch_over_ambiguous_endpoint_is_refused() {
  local id rec out status
  id=reuse-self-unknown-za0
  rec=$(make_case self-unknown "$id")
  read_case "$rec"
  write_owner_meta "$id" "$WT_REAL"
  register_live_tmux_window "$id"
  PANE_COMMAND=node

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "an ambiguously live prior endpoint must not license replacement"
  assert_contains "$out" "is already recorded by this task's own prior launch" \
    "ambiguous self-relaunch refusal did not identify the task's own prior launch"
  assert_contains "$out" "endpoint reported as unknown" \
    "ambiguous self-relaunch refusal did not report the prior endpoint as unknown"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "ambiguous self-relaunch refusal created a second endpoint"
  pass "an ambiguously live prior endpoint refuses a same-task relaunch"
}

test_same_task_relaunch_over_dead_endpoint_is_reclaimed() {
  local id rec out status
  id=reuse-self-dead-z9b
  rec=$(make_case self-dead "$id")
  read_case "$rec"
  write_owner_meta "$id" "$WT_REAL"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a confidently dead prior endpoint must permit the relaunch"$'\n'"$out"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "the relaunched task did not record its own worktree"
  rm -rf "/tmp/fm-$id"
  pass "a stopped worker's own stale metadata is reclaimed by the relaunch"
}

test_endpointless_owner_meta_refuses_with_a_diagnostic() {
  local id rec out status
  id=reuse-no-endpoint-z9c
  rec=$(make_case no-endpoint "$id")
  read_case "$rec"
  write_endpointless_owner_meta owner-endpointless-z9c "$WT_REAL"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "an owner meta with no endpoint must be refused, not silently fatal"
  assert_contains "$out" "is already recorded by task owner-endpointless-z9c" \
    "endpointless-owner refusal did not name the owning task"
  assert_contains "$out" "records no endpoint" \
    "endpointless-owner refusal did not explain that no endpoint could be probed"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "endpointless-owner refusal created a task endpoint"
  pass "metadata naming the worktree with no endpoint fails loudly rather than silently"
}

test_herdr_owner_with_no_running_server_is_reclaimed() {
  local id rec out status
  id=reuse-herdr-down-z9d
  rec=$(make_case herdr-down "$id")
  read_case "$rec"
  write_herdr_owner_meta owner-herdr-down-z9d "$WT_REAL"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a herdr owner with no running server must release the worktree"$'\n'"$out"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "the reclaimed worktree was not recorded for the relaunched task"
  assert_herdr_probe_stayed_passive 0
  rm -rf "/tmp/fm-$id"
  pass "a stopped herdr runtime cannot host a live agent, so its owner is reclaimed without booting it"
}

test_herdr_owner_with_pane_not_found_is_reclaimed() {
  local id rec out status
  id=reuse-herdr-gone-z9f
  rec=$(make_case herdr-gone "$id")
  read_case "$rec"
  write_herdr_owner_meta owner-herdr-gone-z9f "$WT_REAL"
  HERDR_MODE=up
  HERDR_PANE_ERROR=pane_not_found

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a running herdr reporting the pane as gone must release the worktree"$'\n'"$out"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "the reclaimed worktree was not recorded for the relaunched task"
  assert_herdr_probe_stayed_passive 1
  rm -rf "/tmp/fm-$id"
  pass "an endpoint the runtime itself reports as not found is reclaimed"
}

test_herdr_owner_with_missing_cli_is_refused() {
  local id rec out status
  id=reuse-herdr-nocli-z9j
  rec=$(make_case herdr-nocli "$id")
  read_case "$rec"
  write_herdr_owner_meta owner-herdr-nocli-z9j "$WT_REAL"
  hide_tool_from_spawn_path herdr

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "an unreachable herdr CLI must never release the worktree"
  assert_contains "$out" "is already recorded by task owner-herdr-nocli-z9j" \
    "missing-herdr-CLI refusal did not name the owning task"
  assert_contains "$out" "Cannot determine liveness: herdr CLI not found on PATH" \
    "missing-herdr-CLI refusal did not name the condition that blocked the read"
  assert_contains "$out" "Put herdr on PATH, then retry" \
    "missing-herdr-CLI refusal did not tell the operator how to proceed"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "missing-herdr-CLI refusal created a task endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn still recorded metadata for the reused worktree"
  pass "an unreachable herdr CLI is an inability to ask, not evidence the runtime stopped"
}

test_herdr_owner_with_unreadable_status_is_refused() {
  local id rec out status
  id=reuse-herdr-badstatus-z9k
  rec=$(make_case herdr-badstatus "$id")
  read_case "$rec"
  write_herdr_owner_meta owner-herdr-badstatus-z9k "$WT_REAL"
  HERDR_MODE=garbled

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "an unparseable herdr status must not release the worktree"
  assert_contains "$out" "is already recorded by task owner-herdr-badstatus-z9k" \
    "unparseable-status refusal did not name the owning task"
  assert_contains "$out" "Cannot determine liveness: 'herdr status --json' reported no readable server state" \
    "unparseable-status refusal did not name the condition that blocked the read"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "unparseable-status refusal created a task endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn still recorded metadata for the reused worktree"
  pass "a herdr status with no readable server state refuses rather than releasing the path"
}

test_herdr_owner_with_unexpected_pane_error_is_refused() {
  local id rec out status
  id=reuse-herdr-broken-z9g
  rec=$(make_case herdr-broken "$id")
  read_case "$rec"
  write_herdr_owner_meta owner-herdr-broken-z9g "$WT_REAL"
  HERDR_MODE=up
  HERDR_PANE_ERROR=internal_error

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "a running herdr returning an unexpected pane error must not release the worktree"
  assert_contains "$out" "is already recorded by task owner-herdr-broken-z9g" \
    "unexpected-pane-error refusal did not name the owning task"
  assert_contains "$out" "endpoint reported as unknown" \
    "unexpected-pane-error refusal did not report the owning endpoint as unknown"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "unexpected-pane-error refusal created a task endpoint"
  assert_herdr_probe_stayed_passive 1
  pass "an errored pane read on a running herdr refuses instead of releasing the path"
}

test_zellij_owner_with_present_endpoint_is_refused_with_close_instructions() {
  local id rec out status
  id=reuse-zellij-present-z9h
  rec=$(make_case zellij-present "$id")
  read_case "$rec"
  write_zellij_owner_meta owner-zellij-present-z9h "$WT_REAL"

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "a present zellij endpoint with unclassifiable liveness must be refused"
  assert_contains "$out" "is already recorded by task owner-zellij-present-z9h" \
    "zellij-owner refusal did not name the owning task"
  assert_contains "$out" "no verified agent-liveness probe for backend=zellij" \
    "zellij-owner refusal did not explain why liveness cannot be classified"
  assert_contains "$out" "close its pane or workspace zsess:3 first, then retry" \
    "zellij-owner refusal did not tell the operator to close the recorded endpoint"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "zellij-owner refusal created a task endpoint"
  pass "an experimental backend's still-present endpoint refuses with an explicit precondition"
}

test_zellij_owner_with_gone_session_is_reclaimed() {
  local id rec out status
  id=reuse-zellij-gone-z9i
  rec=$(make_case zellij-gone "$id")
  read_case "$rec"
  write_zellij_owner_meta owner-zellij-gone-z9i "$WT_REAL"
  ZELLIJ_SESSION=

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 0 "$status" "a zellij owner whose session is gone must release the worktree"$'\n'"$out"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "the reclaimed worktree was not recorded for the relaunched task"
  assert_contains "$(cat "$ZELLIJ_LOG")" "list-sessions" \
    "the owner probe never asked zellij whether its session was up"
  rm -rf "/tmp/fm-$id"
  pass "a demonstrably gone zellij endpoint is reclaimed once the pane is closed"
}

test_herdr_owner_with_ambiguous_agent_is_refused() {
  local id rec out status
  id=reuse-herdr-ambiguous-z9e
  rec=$(make_case herdr-ambiguous "$id")
  read_case "$rec"
  write_herdr_owner_meta owner-herdr-ambiguous-z9e "$WT_REAL"
  HERDR_MODE=up
  HERDR_AGENT_STATUS=something-unrecognized

  out=$(run_spawn "$id" "$WT_DIR")
  status=$?
  expect_code 1 "$status" "a running herdr whose agent read is ambiguous must refuse"
  assert_contains "$out" "is already recorded by task owner-herdr-ambiguous-z9e" \
    "ambiguous herdr-owner refusal did not name the owning task"
  assert_contains "$out" "endpoint reported as unknown" \
    "ambiguous herdr-owner refusal did not report the owning endpoint as unknown"
  assert_not_contains "$(cat "$TMUX_LOG")" "new-window" \
    "ambiguous herdr-owner refusal created a task endpoint"
  assert_herdr_probe_stayed_passive 1
  pass "a running herdr with an unreadable agent refuses rather than sharing the worktree"
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
test_same_task_relaunch_over_live_endpoint_is_refused
test_same_task_relaunch_over_ambiguous_endpoint_is_refused
test_same_task_relaunch_over_dead_endpoint_is_reclaimed
test_endpointless_owner_meta_refuses_with_a_diagnostic
test_herdr_owner_with_no_running_server_is_reclaimed
test_herdr_owner_with_pane_not_found_is_reclaimed
test_herdr_owner_with_missing_cli_is_refused
test_herdr_owner_with_unreadable_status_is_refused
test_herdr_owner_with_unexpected_pane_error_is_refused
test_herdr_owner_with_ambiguous_agent_is_refused
test_zellij_owner_with_present_endpoint_is_refused_with_close_instructions
test_zellij_owner_with_gone_session_is_reclaimed
test_batch_dispatch_is_refused
test_secondmate_is_refused
test_orca_backend_is_refused

echo "# all fm-spawn-reuse-worktree tests passed"
