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
    "$SPAWN" "$id" "$proj" --reuse-worktree "$wt" --harness prime-agent \
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

test_detection_and_registry() {
  local out
  out=$(PRIME_AGENT_FIRSTMATE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = prime-agent ] || fail "Prime Agent env marker detection returned '$out'"
  "$ROOT/bin/fm-harness.sh" verified | grep -qx prime-agent \
    || fail "Prime Agent is absent from the verified registry"
  pass "fm-harness: Prime Agent marker and verified registry entry are present"
}

test_tmux_node_process_is_classified_by_foreground_args() {
  local d fakebin out
  d="$TMP_ROOT/liveness"
  fakebin=$(fm_fakebin "$d")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "list-windows -t firstmate -F #{window_name}") printf 'fm-prime-live\n' ;;
  *"#{pane_current_command}"*) printf 'node\n' ;;
  *"#{pane_pid}"*) printf '4242\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-o tpgid= -p 4242") printf ' 777\n' ;;
  "-ax -o pgid=,args=") printf ' 777 node /home/test/.local/prime-agent/node_modules/.bin/prime-agent --model test\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/ps"
  out=$(FM_BACKEND_LIB_DIR="$ROOT/bin" PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$1/bin/backends/tmux.sh"; fm_backend_tmux_agent_state firstmate:fm-prime-live' _ "$ROOT")
  [ "$out" = alive ] || fail "tmux should classify Prime Agent's foreground node argv alive, got '$out'"
  pass "tmux liveness: foreground node is alive only when argv identifies prime-agent"
}

test_control_adapter_state_send_and_cleanup
test_spawn_launch_and_event_extension
test_detection_and_registry
test_tmux_node_process_is_classified_by_foreground_args
