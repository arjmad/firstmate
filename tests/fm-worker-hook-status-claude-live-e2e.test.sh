#!/usr/bin/env bash
# Opt-in real-Claude guard for the worker status hooks.
#
# bin/fm-worker-hook-status.sh turns three vendor-emitted Claude Code hook
# events into status lines: Notification idle_prompt, SessionEnd, and
# StopFailure. tests/fm-worker-hook-status.test.sh and
# tests/fm-busy-adapter-wiring.test.sh pin the writer and the spawn wiring
# against hand-written payloads; this guard proves the installed Claude Code
# still fires those events in a detached tmux pane with the payload fields the
# writer reads (session_id, notification_type, reason, error), by launching the
# real harness and reading the status log the hooks wrote. It submits prompts,
# so it is opt-in: FM_CLAUDE_WORKER_HOOKS_LIVE=1 (or FM_LIVE=1). A failure
# names the Claude Code version and shows the pane.
#
# Isolation: a throwaway lab holds the project, a linked worktree the agent runs
# in (trusted through the production bin/fm-claude-trust.sh path), the state
# directory, and the tmux server (TMUX_TMPDIR), so no fleet home or shared tmux
# server is touched. The worktree's .claude/settings.local.json carries the same
# writer commands bin/fm-spawn.sh installs for a crewmate, beside the busy
# writer's session binding they depend on.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_WORKER_HOOKS_LIVE claude tmux git jq
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')
ID=hookstatus$$
SESSION=fm-hook-status-$$
LAB=
lt() {  # tmux on the lab's dedicated server, never the caller's
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB" tmux "$@"
}
cleanup() {
  [ -n "$LAB" ] || return 0
  lt kill-server >/dev/null 2>&1 || true
  git -C "$LAB/project" worktree remove --force "$LAB/wt" >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT
pane() {
  lt capture-pane -p -t "$SESSION:w" -S -40 2>/dev/null || true
}
wait_pane() {  # <seconds> <grep -E pattern>
  local i=0
  while [ "$i" -lt "$1" ]; do
    pane | grep -Eq "$2" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
wait_status() {  # <seconds> <grep -E pattern>: poll the status log the hooks write
  local i=0
  while [ "$i" -lt "$1" ]; do
    grep -Eq "$2" "$STATUS" 2>/dev/null && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
lines() { grep -c . "$STATUS" 2>/dev/null || echo 0; }
launch() {  # [extra claude args]
  # Clear the previous session's render so the composer check below sees only this one.
  lt send-keys -t "$SESSION:w" -l 'clear'
  lt send-keys -t "$SESSION:w" Enter
  sleep 0.5
  lt clear-history -t "$SESSION:w"
  rm -f "$LAB/turn-ended"
  lt send-keys -t "$SESSION:w" -l "cd '$LAB/wt' && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions $*"
  lt send-keys -t "$SESSION:w" Enter
  wait_pane 60 'bypass permissions on' || fail "Claude Code $CLAUDE_VERSION did not reach its composer:"$'\n'"$(pane)"
}
submit() {  # <text>
  lt send-keys -t "$SESSION:w" -l "$1"
  sleep 1.2
  lt send-keys -t "$SESSION:w" Enter
}
wait_shell() {  # the pane's foreground is the shell again
  local i=0 cmd
  while [ "$i" -lt 30 ]; do
    cmd=$(lt display-message -p -t "$SESSION:w" '#{pane_current_command}' 2>/dev/null || true)
    case "$cmd" in *sh) return 0 ;; esac
    sleep 1
    i=$((i + 1))
  done
  fail "Claude Code $CLAUDE_VERSION did not exit:"$'\n'"$(pane)"
}

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-hook-status-live.XXXXXX") || fail "could not create the lab"
LAB=$(cd "$LAB" && pwd -P)
STATE="$LAB/state"
STATUS="$STATE/$ID.status"
mkdir -p "$STATE" "$LAB/config" "$LAB/project"
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" -c user.email=hook-status@example.invalid -c user.name='hook status test' \
  commit -q --allow-empty -m 'fixture: hook status probe'
git -C "$LAB/project" worktree add -q "$LAB/wt" -b probe
"$ROOT/bin/fm-claude-trust.sh" "$LAB/wt" "$LAB/project" >/dev/null \
  || fail "could not pre-register workspace trust for the probe worktree"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") || fail "could not arm the probe incarnation"
q() { printf "'%s'" "$1"; }
busy="$(q "$ROOT/bin/fm-busy-event.sh") apply $(q "$STATE") $(q "$ID")"
suffix="--gen $(q "$GEN") --source claude-hook --session-from-payload"
writer() { printf '%s %s %s %s --gen %s --config %s' "$(q "$ROOT/bin/fm-worker-hook-status.sh")" "$1" "$(q "$STATE")" "$(q "$ID")" "$(q "$GEN")" "$(q "$LAB/config")"; }
mkdir -p "$LAB/wt/.claude"
jq -n \
  --arg submit "$busy busy $suffix --event user-prompt-submit 2>/dev/null || true" \
  --arg stop "touch $(q "$LAB/turn-ended")" \
  --arg stopfail "$(writer stop-failure) >/dev/null 2>&1 || true" \
  --arg idle "$(writer idle) >/dev/null 2>&1 || true" \
  --arg end "fm_hook_payload=\$(cat); printf '%s' \"\$fm_hook_payload\" | $(writer session-end) >/dev/null 2>&1; printf '%s' \"\$fm_hook_payload\" | $busy idle $suffix --event session-end 2>/dev/null || true" \
  '{hooks: {
     UserPromptSubmit: [{hooks: [{type: "command", command: $submit}]}],
     Stop: [{hooks: [{type: "command", command: $stop}]}],
     StopFailure: [{hooks: [{type: "command", command: $stopfail}]}],
     SessionEnd: [{hooks: [{type: "command", command: $end}]}],
     Notification: [{matcher: "idle_prompt", hooks: [{type: "command", command: $idle}]}]
   }}' > "$LAB/wt/.claude/settings.local.json" || fail "could not write the probe hooks"

lt new-session -d -s "$SESSION" -n w -x 120 -y 40 -c "$LAB/wt" \
  || fail "could not create the lab's tmux server"

# idle_prompt: a turn that ends after a working line, then a minute of quiet.
launch
printf 'working [at=%s]: probe started\n' "$(date +%s)" >> "$STATUS"
submit "Reply with exactly the word OK and nothing else."
wait_status 150 '^paused \[at=[0-9]+\]: idle at the prompt .*idle_prompt hook' \
  || fail "Claude Code $CLAUDE_VERSION fired no idle_prompt the writer accepted within 150s; log:"$'\n'"$(cat "$STATUS")"$'\n'"$(pane)"
pass "Claude Code $CLAUDE_VERSION: idle_prompt in a detached pane declares the worker's pause"

# SessionEnd: an exit nobody recorded is a blocker naming the vendor reason.
submit "/exit"
wait_shell
wait_status 15 '^blocked \[at=[0-9]+\]: Claude Code session ended \(prompt_input_exit\)' \
  || fail "Claude Code $CLAUDE_VERSION's /exit wrote no session-end blocker; log:"$'\n'"$(cat "$STATUS")"
pass "Claude Code $CLAUDE_VERSION: /exit reports an unexpected session end as a blocker"

# SessionEnd after firstmate's own expect-exit record stays quiet.
printf 'resolved [at=%s]: probe continues\n' "$(date +%s)" >> "$STATUS"
launch
submit "Reply with exactly the word OK and nothing else."
i=0
until [ -e "$LAB/turn-ended" ]; do
  [ "$i" -lt 60 ] || fail "Claude Code $CLAUDE_VERSION did not finish the second prompt:"$'\n'"$(pane)"
  sleep 1
  i=$((i + 1))
done
"$ROOT/bin/fm-worker-hook-status.sh" expect-exit "$STATE" "$ID" || fail "expect-exit failed"
before=$(lines)
submit "/exit"
wait_shell
sleep 2
[ "$(lines)" -eq "$before" ] \
  || fail "Claude Code $CLAUDE_VERSION: an exit firstmate recorded was still reported; log:"$'\n'"$(cat "$STATUS")"
pass "Claude Code $CLAUDE_VERSION: an exit firstmate recorded writes no status line"

# StopFailure: a model the account cannot use ends the turn on an API error.
rm -f "$STATE/$ID.exit-expected"
launch --model claude-nonexistent-hook-probe
submit "Reply with exactly the word OK and nothing else."
wait_status 90 '^blocked \[at=[0-9]+\]: Claude Code turn ended on API error model_not_found' \
  || fail "Claude Code $CLAUDE_VERSION wrote no StopFailure blocker for an unknown model; log:"$'\n'"$(cat "$STATUS")"$'\n'"$(pane)"
pass "Claude Code $CLAUDE_VERSION: an API-error turn end reports a blocker naming the error"
submit "/exit"
wait_shell
