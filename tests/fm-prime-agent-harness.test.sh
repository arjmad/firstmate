#!/usr/bin/env bash
# Behavior tests for the experimental Prime Agent v0.7.1 crew adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prime-agent)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_BIN=$(command -v jq) || fail "test needs jq"
PRIME_CTL="$ROOT/bin/fm-prime-agent.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

make_prime_fake() {
  local fakebin=$1
  cat > "$fakebin/prime-agent" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmp=%s sessions=%s telemetry=%s dnt=%s marker=%s cmd=%s\n' \
  "${TMPDIR:-}" "${PRIME_AGENT_SESSION_DIR:-}" "${PRIME_AGENT_TELEMETRY:-}" \
  "${DO_NOT_TRACK:-}" "${PRIME_AGENT_FIRSTMATE:-}" "$*" >> "${FM_FAKE_PRIME_LOG:?}"
case "${1:-}" in
  list)
    cat <<JSON
{"sessions":[{"id":"pa123","activeSessionId":"pa123","lifecycle":"live","cwd":"${FM_FAKE_PRIME_CWD:?}","activity":"${FM_FAKE_PRIME_ACTIVITY:-idle}","isStreaming":${FM_FAKE_PRIME_STREAMING:-false},"isRunningTools":false,"isBashRunning":false,"isCompacting":false,"hasRunningRlmChildren":false,"unfinishedActionCount":0}]}
JSON
    ;;
  send) printf '{"deliveryStatus":"queued","deliveryMode":"steer"}\n' ;;
  stop) printf '{"stopped":true}\n' ;;
  shutdown) printf '{"shutdown":true}\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/prime-agent"
}

make_tmux_fake() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{pane_current_command}"*) printf 'node\n'; exit 0 ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_PANE_PID:-$$}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) exit 0 ;;
  new-window) printf '@1\n' ;;
  has-session|new-session|set-window-option|send-keys|kill-window|capture-pane) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

make_case() {
  local d=$1 id=$2 fakebin home proj wt
  fakebin=$(fm_fakebin "$d")
  home="$d/home"
  proj="$d/project"
  wt="$d/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  printf 'Prime Agent test brief.\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$d/prime.log"
  : > "$d/tmux.log"
  make_prime_fake "$fakebin"
  make_tmux_fake "$fakebin"
  ln -s "$JQ_BIN" "$fakebin/jq"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$id"
}

assert_scoped_log() {
  local log=$1 tmp=$2 sessions=$3
  assert_grep "tmp=$tmp sessions=$sessions telemetry=0 dnt=1 marker=1" "$log" \
    "Prime Agent command lost task paths, telemetry opt-outs, or detection marker"
}

test_control_adapter_state_send_and_cleanup() {
  local d fakebin home state id tmp sessions meta out
  d="$TMP_ROOT/control"
  fakebin=$(fm_fakebin "$d")
  make_prime_fake "$fakebin"
  make_tmux_fake "$fakebin"
  ln -s "$JQ_BIN" "$fakebin/jq"
  home="$d/home"
  state="$home/state"
  id=prime-control-a1
  tmp=$(mktemp -d /tmp/fmpa.XXXXXXXX)
  mkdir -p "$state" "$d/cwd"
  state=$(cd "$state" && pwd -P)
  touch "$state/.last-watcher-beat"
  sessions="$state/prime-agent/$id/sessions"
  mkdir -p "$sessions"
  : > "$d/prime.log"
  : > "$d/tmux.log"
  meta="$state/$id.meta"
  fm_write_meta "$meta" "window=firstmate:fm-$id" "worktree=$d/cwd" \
    "project=$d/cwd" "harness=prime-agent" "kind=scout" \
    "prime_tmp=$tmp" "prime_session_dir=$sessions" "prime_session=pa123"

  out=$(HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$(cd "$d/cwd" && pwd -P)" \
    "$PRIME_CTL" discover "$tmp" "$sessions" "$d/cwd")
  [ "$out" = pa123 ] || fail "Prime Agent discovery should return activeSessionId, got '$out'"
  out=$(HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$d/cwd" \
    FM_FAKE_PRIME_ACTIVITY=working "$PRIME_CTL" state "$meta")
  [ "$out" = busy ] || fail "Prime Agent working list state should be busy, got '$out'"
  out=$(HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$d/cwd" \
    FM_FAKE_PRIME_ACTIVITY=idle "$PRIME_CTL" state "$meta")
  [ "$out" = idle ] || fail "Prime Agent idle list state should be idle, got '$out'"

  HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$d/cwd" \
    "$PRIME_CTL" send "$meta" 'change course' >/dev/null
  assert_grep 'cmd=send pa123 change course --json' "$d/prime.log" \
    "Prime Agent steer did not use plain send"
  assert_no_grep '--steer' "$d/prime.log" "Prime Agent used broken --steer flag"

  HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" FM_FAKE_PRIME_LOG="$d/prime.log" \
    FM_FAKE_PRIME_CWD="$d/cwd" FM_FAKE_TMUX_LOG="$d/tmux.log" \
    FM_SEND_SETTLE=0 PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-send.sh" "$id" 'steer through firstmate' >/dev/null
  assert_grep 'cmd=send pa123 steer through firstmate --json' "$d/prime.log" \
    "fm-send did not route Prime Agent text through daemon steering"
  assert_no_grep 'send-keys' "$d/tmux.log" "fm-send typed Prime Agent steering into the pane"

  HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$d/cwd" \
    "$PRIME_CTL" cleanup "$meta"
  assert_grep 'cmd=stop pa123 --json' "$d/prime.log" "cleanup did not stop the task session"
  assert_grep 'cmd=shutdown --force --json' "$d/prime.log" "cleanup did not force-shutdown the task daemon"
  assert_scoped_log "$d/prime.log" "$tmp" "$sessions"
  rm -rf "$tmp"
  pass "fm-prime-agent: list state, plain-send steer, and task-scoped cleanup are isolated"
}

test_spawn_launch_and_event_extension() {
  local d rec home proj wt fakebin id out rc meta launch tmp sessions ext
  d="$TMP_ROOT/spawn"
  id=prime-spawn-b2
  rec=$(make_case "$d" "$id")
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF
  rc=0
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_PRIME_CWD="$(cd "$wt" && pwd -P)" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_TMUX_LOG="$d/tmux.log" \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --scout --harness prime-agent \
      --model gpt-5.6-sol --effort high 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "Prime Agent spawn should succeed: $out; prime log: $(cat "$d/prime.log")"
  assert_contains "$out" "spawned $id harness=prime-agent" "Prime Agent spawn did not report success"

  meta="$home/state/$id.meta"
  tmp=$(sed -n 's/^prime_tmp=//p' "$meta")
  sessions=$(sed -n 's/^prime_session_dir=//p' "$meta")
  ext="$home/state/$id.prime-ext.ts"
  assert_grep 'prime_session=pa123' "$meta" "spawn did not record activeSessionId"
  assert_grep 'model=gpt-5.6-sol' "$meta" "spawn lost model"
  assert_grep 'effort=high' "$meta" "spawn lost effort"
  assert_present "$ext" "spawn did not write the task extension"
  assert_grep 'prime.on("agent_end"' "$ext" "extension does not use agent_end"
  assert_grep 'prime.on("session_shutdown"' "$ext" "extension lacks session_shutdown"
  assert_no_grep 'turn_end' "$ext" "extension incorrectly uses turn_end"

  launch=$(grep 'send-keys .* -l ' "$d/tmux.log" | tail -1)
  assert_contains "$launch" "fm-prime-agent.sh' launch '$tmp' '$sessions'" \
    "launch omitted the task-scoped control wrapper and runtime paths"
  assert_contains "$launch" "--model 'gpt-5.6-sol' --thinking 'high'" \
    "launch did not thread model and effort mapping"
  assert_contains "$launch" "--extension '$ext' --" "launch omitted extension or positional separator"
  assert_scoped_log "$d/prime.log" "$tmp" "$sessions"

  HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$wt" \
    FM_FAKE_TMUX_LOG="$d/tmux.log" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null
  assert_absent "$meta" "teardown left Prime Agent metadata"
  assert_absent "$tmp" "teardown left Prime Agent's short TMPDIR"
  assert_absent "$ext" "teardown left the Prime Agent event extension"
  assert_absent "$home/state/prime-agent/$id" "teardown left task session storage"
  pass "fm-spawn/fm-teardown: Prime Agent launch and cleanup preserve every task isolation boundary"
}

test_cleanup_idempotent_when_runtime_already_gone() {
  local d fakebin home state id tmp sessions meta rc
  d="$TMP_ROOT/cleanup-gone"
  fakebin=$(fm_fakebin "$d")
  make_prime_fake "$fakebin"
  ln -s "$JQ_BIN" "$fakebin/jq"
  home="$d/home"
  state="$home/state"
  id=prime-gone-c3
  mkdir -p "$state"
  state=$(cd "$state" && pwd -P)
  tmp=$(mktemp -d /tmp/fmpa.XXXXXXXX)
  sessions="$state/prime-agent/$id/sessions"
  meta="$state/$id.meta"
  : > "$d/prime.log"

  fm_write_meta "$meta" "harness=prime-agent" \
    "prime_tmp=$tmp" "prime_session_dir=$sessions"
  rm -rf "$tmp"
  rc=0
  HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" "$PRIME_CTL" cleanup "$meta" || rc=$?
  [ "$rc" = 0 ] || fail "cleanup should treat an already-removed runtime with no session id as done, rc=$rc"
  [ ! -s "$d/prime.log" ] || fail "cleanup invoked prime-agent for an absent runtime: $(cat "$d/prime.log")"

  mkdir -p "$tmp" "$sessions"
  fm_write_meta "$meta" "harness=prime-agent" \
    "prime_tmp=$tmp" "prime_session_dir=$sessions" "prime_session=pa123"
  rc=0
  HOME="$d/nohome" PATH="$BASE_PATH" "$PRIME_CTL" cleanup "$meta" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] || fail "cleanup should succeed when the prime-agent executable is gone, rc=$rc"

  fm_write_meta "$meta" "harness=prime-agent" \
    "prime_tmp=$tmp" "prime_session_dir=$state/prime-agent/other-task/sessions" \
    "prime_session=pa123"
  rc=0
  HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" "$PRIME_CTL" cleanup "$meta" 2>/dev/null || rc=$?
  [ "$rc" != 0 ] || fail "cleanup accepted a session directory owned by another task"

  fm_write_meta "$meta" "harness=prime-agent" \
    "prime_tmp=/tmp/evil" "prime_session_dir=$sessions" "prime_session=pa123"
  rc=0
  HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" "$PRIME_CTL" cleanup "$meta" 2>/dev/null || rc=$?
  [ "$rc" != 0 ] || fail "cleanup accepted an unsafe task TMPDIR"

  fm_write_meta "$meta" "harness=prime-agent" "prime_tmp=$tmp"
  rc=0
  HOME="$home" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" "$PRIME_CTL" cleanup "$meta" 2>/dev/null || rc=$?
  [ "$rc" != 0 ] || fail "cleanup accepted a partially recorded runtime"

  rm -rf "$tmp"
  pass "fm-prime-agent: cleanup is idempotent for an already-gone runtime and fail-closed on unsafe paths"
}

test_teardown_succeeds_after_failed_launch() {
  local d rec home proj wt fakebin id out rc meta tmp
  d="$TMP_ROOT/failed-launch"
  id=prime-fail-d4
  rec=$(make_case "$d" "$id")
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF
  rc=0
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_PRIME_CWD="$d/elsewhere" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_TMUX_LOG="$d/tmux.log" \
    FM_PRIME_SESSION_POLLS=1 FM_PRIME_POLL_INTERVAL=0 \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --scout --harness prime-agent 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "spawn should fail when discovery finds no task session: $out"

  meta="$home/state/$id.meta"
  assert_present "$meta" "failed spawn should leave task metadata behind for teardown"
  assert_no_grep 'prime_session=' "$meta" "failed spawn must not record a session id"
  tmp=$(sed -n 's/^prime_tmp=//p' "$meta")
  [ -n "$tmp" ] || fail "failed spawn metadata lost prime_tmp"
  [ ! -d "$tmp" ] || fail "spawn abort cleanup left the task TMPDIR behind"

  rc=0
  out=$(HOME="$home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" \
    FM_FAKE_PRIME_LOG="$d/prime.log" FM_FAKE_PRIME_CWD="$wt" \
    FM_FAKE_TMUX_LOG="$d/tmux.log" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "teardown must succeed after a failed Prime Agent launch: $out"
  assert_absent "$meta" "teardown left Prime Agent metadata after a failed launch"
  assert_absent "$home/state/prime-agent/$id" "teardown left task session storage after a failed launch"
  pass "fm-teardown: an aborted Prime Agent launch no longer wedges task teardown"
}

test_detection_and_registry() {
  local out
  out=$(PRIME_AGENT_FIRSTMATE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = prime-agent ] || fail "Prime Agent env marker detection returned '$out'"
  "$ROOT/bin/fm-harness.sh" verified | grep -qx prime-agent \
    || fail "Prime Agent is absent from the verified registry"
  pass "fm-harness: Prime Agent marker and verified registry entry are present"
}


# The busy-state seam: prime-agent is a PULL source. Nothing is armed for it, so
# the classifier must reach its adapter on demand and must never fall through to
# idle when that read cannot settle the turn.
classify_prime() {  # <state-dir> <id>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux fake:0 prime-agent "$2" "$1"
  )
}

test_busy_classification_uses_the_list_verdict() {
  local d fakebin home state id tmp sessions meta verdict
  d="$TMP_ROOT/busy"
  fakebin=$(fm_fakebin "$d")
  make_prime_fake "$fakebin"
  ln -s "$JQ_BIN" "$fakebin/jq"
  home="$d/home"
  state="$home/state"
  id=prime-busy-e5
  tmp=$(mktemp -d /tmp/fmpa.XXXXXXXX)
  mkdir -p "$state" "$d/cwd"
  state=$(cd "$state" && pwd -P)
  sessions="$state/prime-agent/$id/sessions"
  mkdir -p "$sessions"
  : > "$d/prime.log"
  meta="$state/$id.meta"
  fm_write_meta "$meta" "window=firstmate:fm-$id" "worktree=$d/cwd" \
    "project=$d/cwd" "harness=prime-agent" "kind=scout" \
    "prime_tmp=$tmp" "prime_session_dir=$sessions" "prime_session=pa123"

  verdict=$(PATH="$fakebin:$BASE_PATH" HOME="$home" \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" FM_FAKE_PRIME_LOG="$d/prime.log" \
    FM_FAKE_PRIME_CWD="$d/cwd" FM_FAKE_PRIME_ACTIVITY=working classify_prime "$state" "$id")
  [ "$verdict" = "busy prime-agent-list" ] \
    || fail "a working Prime Agent session should classify busy from its own list verdict, got '$verdict'"

  verdict=$(PATH="$fakebin:$BASE_PATH" HOME="$home" \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" FM_FAKE_PRIME_LOG="$d/prime.log" \
    FM_FAKE_PRIME_CWD="$d/cwd" FM_FAKE_PRIME_ACTIVITY=idle classify_prime "$state" "$id")
  [ "$verdict" = "idle prime-agent-list" ] \
    || fail "an idle Prime Agent session should classify idle from its own list verdict, got '$verdict'"

  # A session the daemon no longer knows about proves nothing about the turn, so
  # it must stay unknown rather than reading as a finished one.
  fm_write_meta "$meta" "window=firstmate:fm-$id" "worktree=$d/cwd" \
    "project=$d/cwd" "harness=prime-agent" "kind=scout" \
    "prime_tmp=$tmp" "prime_session_dir=$sessions" "prime_session=gone999"
  verdict=$(PATH="$fakebin:$BASE_PATH" HOME="$home" \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" FM_FAKE_PRIME_LOG="$d/prime.log" \
    FM_FAKE_PRIME_CWD="$d/cwd" classify_prime "$state" "$id")
  [ "$verdict" = "unknown prime-agent-list" ] \
    || fail "a missing Prime Agent session must be unknown, never idle, got '$verdict'"

  # An unreachable adapter is the same kind of non-evidence.
  verdict=$(PATH="$BASE_PATH" HOME="$d/nohome" classify_prime "$state" "$id")
  [ "$verdict" = "unknown prime-agent-list" ] \
    || fail "an unreadable Prime Agent state must be unknown, got '$verdict'"

  # Nothing may be armed for this adapter: a seeded record with no writer to
  # clear it could never settle.
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    [ -z "$(fm_busy_sources_for_harness prime-agent)" ]
  ) || fail "prime-agent must trust no written busy source, because it has no writer"
  rm -rf "$tmp"
  pass "fm-busy-lib: prime-agent classifies from its own list verdict and never falls through to idle"
}

# The control plane: prime-agent has a verified interrupt and no verified way to
# stop the agent, so it must offer exactly the half it can prove.
test_control_offers_interrupt_only() {
  (
    # shellcheck source=bin/fm-control-lib.sh
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_harness_supported prime-agent || exit 1
    [ "$(fm_control_harness_family prime-agent)" = prime-agent ] || exit 1
    [ "$(fm_control_interrupt_key prime-agent)" = Escape ] || exit 1
    [ "$(fm_control_interrupt_repeat prime-agent)" = 1 ] || exit 1
    fm_control_harness_supports_verb prime-agent interrupt || exit 1
    ! fm_control_harness_supports_verb prime-agent exit || exit 1
    ! fm_control_harness_supports_verb prime-agent relaunch || exit 1
    ! fm_control_exit_command prime-agent >/dev/null 2>&1 || exit 1
    fm_control_harness_supports_kind prime-agent scout || exit 1
    ! fm_control_harness_supports_kind prime-agent secondmate || exit 1
  ) || fail "the control tables do not describe prime-agent's verified mechanics"
  pass "fm-control-lib: prime-agent offers a verified interrupt and refuses the verbs it cannot prove"
}

test_secondmate_and_relaunch_are_refused() {
  local d rec home proj wt fakebin id out rc
  d="$TMP_ROOT/refusals"
  id=prime-refuse-f6
  rec=$(make_case "$d" "$id")
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF
  rc=0
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_TMUX_LOG="$d/tmux.log" \
    PRIME_AGENT_REAL_BIN="$fakebin/prime-agent" PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$home/sm" --secondmate --harness prime-agent 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a prime-agent secondmate spawn must be refused: $out"
  assert_contains "$out" "crewmate/scout adapter only" \
    "the secondmate refusal should name the adapter boundary"
  pass "fm-spawn: prime-agent is refused for a secondmate"
}

test_control_adapter_state_send_and_cleanup
test_spawn_launch_and_event_extension
test_cleanup_idempotent_when_runtime_already_gone
test_teardown_succeeds_after_failed_launch
test_detection_and_registry
test_busy_classification_uses_the_list_verdict
test_control_offers_interrupt_only
test_secondmate_and_relaunch_are_refused
