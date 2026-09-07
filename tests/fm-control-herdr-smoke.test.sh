#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# combines herdr's native registry with positive kernel shell evidence.
#
# No real agent is launched. Custom registrations keep their refusal contract;
# official Pi reports must demonstrably install full-lifecycle authority before
# the stale-authority cases can pass (CLI success alone is not proof).
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${HERDR_LAB_SESSION:-$("$HERDR_LAB_HELPER" name control-smoke)}
export HERDR_SESSION="$SESSION" HERDR_LAB_SESSION="$SESSION" HERDR_LAB_HELPER
export FM_HERDR_TEST_REAL_PATH="$PATH"
SCRATCH=
cleanup_all() {
  PATH="$FM_HERDR_TEST_REAL_PATH" "$HERDR_LAB_HELPER" teardown "$SESSION" || return 1
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
# Route even subprocess/backend calls through the guarded helper. It sees the
# original PATH, so this shim cannot recurse; lifecycle calls remain refused.
mkdir -p "$SCRATCH/bin"
export FM_HERDR_TEST_CALLS="$SCRATCH/calls"
cat > "$SCRATCH/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_HERDR_TEST_CALLS"
if [ "${1:-} ${2:-}" = 'pane process-info' ]; then
  case "${FM_HERDR_TEST_PROCESS_FAULT:-}" in
    unreadable) exit 1 ;;
    ambiguous) printf '{"result":{"type":"pane_process_info","process_info":{}}}\n'; exit 0 ;;
  esac
fi
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n - 2))]}" = --session ]; then
  [ "${args[$((n - 1))]}" = "$HERDR_LAB_SESSION" ] || exit 1
  unset 'args[n-1]' 'args[n-2]'
fi
PATH="$FM_HERDR_TEST_REAL_PATH" exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$SCRATCH/bin/herdr"
export PATH="$SCRATCH/bin:$PATH"
printf 'installed Herdr: '
herdr status --json || fail "could not record installed Herdr version/protocol"
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"
herdr agent get "$PANE_ID" --session "$SESSION" | jq -e '.result.agent.screen_detection_skipped != true' >/dev/null \
  || fail "custom-source fixture unexpectedly installed native full-lifecycle authority"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true

# --- stale official authority: non-vacuous native report + kernel proof -----

native_report() {
  herdr pane report-agent "$PANE_ID" --source herdr:pi --agent pi --state idle \
    --agent-session-path "$SCRATCH/pi-session.jsonl" --session "$SESSION" >/dev/null \
    || fail "installed Herdr rejected official Pi source report"
  local native explain
  native=$(herdr agent get "$PANE_ID" --session "$SESSION") || fail "official Pi report did not register an agent"
  printf '%s' "$native" | jq -e --arg pane "$PANE_ID" '
    .result.agent.pane_id == $pane and .result.agent.agent == "pi"
    and .result.agent.screen_detection_skipped == true
  ' >/dev/null || fail "NOT VERIFIED: official-source CLI report did not establish native full-lifecycle authority: $native"
  explain=$(herdr agent explain "$PANE_ID" --session "$SESSION") || fail "cannot inspect native authority reason"
  printf '%s' "$explain" | jq -e '
    .. | objects | select(.screen_detection_skip_reason? == "full_lifecycle_hook_authority")
  ' >/dev/null || fail "NOT VERIFIED: native authority reason is not full_lifecycle_hook_authority: $explain"
}

assert_no_control_mutation() {
  if grep -E '^(pane (send-text|send-keys|run|close|release-agent|report-agent)|tab (create|close)) ' "$FM_HERDR_TEST_CALLS" >/dev/null; then
    fail "stale-authority exit mutated the pane before proving it already stopped"
  fi
}

printf '{"type":"session","version":3,"id":"fm-control-smoke","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}\n' > "$SCRATCH/pi-session.jsonl"
for shape in plain nested; do
  TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-native-$shape" "$WT" "") \
    || fail "could not create native-authority $shape fixture"
  read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
  # Use a known quiet shell so user prompt helpers cannot masquerade as a
  # childless shell. exec preserves the real pane shell pid for the plain case.
  herdr pane run "$PANE_ID" 'exec /bin/sh -i' --session "$SESSION" >/dev/null \
    || fail "could not establish plain shell fixture"
  shell_pid=
  for _ in $(seq 1 100); do
    shell_pid=$(fm_backend_herdr_pane_idle_shell_sample "$SESSION" "$PANE_ID") && break
    sleep 0.05
  done
  [ -n "$shell_pid" ] || fail "plain shell fixture never settled"
  if [ "$shape" = nested ]; then
    herdr pane run "$PANE_ID" '/bin/sh -i' --session "$SESSION" >/dev/null || fail "could not start nested shell"
    for _ in $(seq 1 100); do
      info=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION") || fail "nested process-info unreadable"
      printf '%s' "$info" | jq -e '.result.process_info | .shell_pid != .foreground_process_group_id' >/dev/null && break
      sleep 0.05
    done
    printf '%s' "$info" | jq -e '.result.process_info | .shell_pid != .foreground_process_group_id' >/dev/null \
      || fail "nested fixture did not diverge from the pane shell"
  fi
  # Separate task-local record; never reuse a production home or allocation.
  {
    printf 'window=%s:%s\nbackend=herdr\nharness=pi\nendpoint_task_id=native\n' "$SESSION" "$PANE_ID"
    printf 'kind=ship\nmode=no-mistakes\nyolo=off\nworktree=%s\nproject=%s\n' "$WT" "$PROJ"
    printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$WORKSPACE_ID" "$TAB_ID" "$PANE_ID"
  } > "$HOME_DIR/state/native.meta"
  native_report
  : > "$FM_HERDR_TEST_CALLS"
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = dead ] || fail "$shape shell with proven native authority should be dead, got $STATE"
  OUT=$(run_control native exit) || fail "$shape stale-authority exit failed: $OUT"
  case "$OUT" in "already-stopped native"*) ;; *) fail "unexpected stale-authority exit result: $OUT" ;; esac
  assert_no_control_mutation
  pass "real herdr: verified official stale authority on $shape shell permits already-stopped without pane mutation"
  for fault in unreadable ambiguous; do
    : > "$FM_HERDR_TEST_CALLS"
    STATE=$(FM_HERDR_TEST_PROCESS_FAULT=$fault fm_backend_agent_state herdr "$SESSION:$PANE_ID")
    [ "$STATE" = unreadable ] || fail "$fault process-info transport must not establish absence, got $STATE"
    if OUT=$(FM_HERDR_TEST_PROCESS_FAULT=$fault run_control native exit); then
      fail "$fault process-info transport unexpectedly allowed exit: $OUT"
    fi
    assert_no_control_mutation
    pass "real herdr fixture: injected $fault process-info transport refuses before any pane mutation"
  done

  herdr pane run "$PANE_ID" 'sleep 300' --session "$SESSION" >/dev/null || fail "could not launch foreground work"
  for _ in $(seq 1 100); do
    info=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION") || fail "foreground process-info unreadable"
    printf '%s' "$info" | jq -e '[.result.process_info.foreground_processes[] | select(.name | endswith("sleep"))] | length > 0' >/dev/null && break
    sleep 0.05
  done
  printf '%s' "$info" | jq -e '[.result.process_info.foreground_processes[] | select(.name | endswith("sleep"))] | length > 0' >/dev/null \
    || fail "foreground-child fixture did not launch a real sleep process"
  native_report
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = alive ] || fail "native authority with actual foreground work should stay alive, got $STATE"
  if OUT=$(run_control native exit); then
    fail "active foreground work was incorrectly reported stopped: $OUT"
  fi
  case "$OUT" in *"did not stop"*) ;; *) fail "unexpected active-child refusal: $OUT" ;; esac
  pass "real herdr: actual foreground child under $shape shell preserves authority and exit refusal"
  fm_backend_herdr_kill "$SESSION:$PANE_ID" || fail "could not close private native fixture"
done

# Cleanup is a test assertion, not a warning hidden by the EXIT trap.
cleanup_all || fail "isolated lab cleanup or live-default tripwire failed"
trap - EXIT
