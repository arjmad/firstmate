#!/usr/bin/env bash
# Opt-in real-Claude guard for the exit-confirmation dialog contract.
#
# bin/fm-control-lib.sh's fm_control_exit_confirm_dialog reads a vendor-rendered
# surface: the "Background work is running" dialog Claude Code raises when
# `/exit` is submitted while a background shell is live, with its selection on
# `1. Exit and stop tasks`. tests/fm-control.test.sh pins the control plane's
# logic against a captured rendering; this guard proves the rendering itself is
# still what the installed Claude Code produces, by launching the real harness
# in a dedicated tmux server, starting a background shell through a prompt, and
# driving `bin/fm-control.sh <id> exit` for real. It spends model tokens, so it
# is opt-in: FM_CLAUDE_EXIT_CONFIRM_LIVE=1 (or FM_LIVE=1). A failure names the
# Claude Code version and shows the pane, so a changed dialog is caught here
# rather than by a worker that never stops.
#
# Isolation: a throwaway lab holds the project, a linked worktree the agent runs
# in (trusted through the production bin/fm-claude-trust.sh path, exactly as a
# spawn would), the firstmate home, and the tmux server (TMUX_TMPDIR), so no
# shared tmux server or fleet home is touched. The background shell sleeps for
# an unusual duration so its survival can be checked by name without matching
# anything else on the machine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_EXIT_CONFIRM_LIVE claude tmux git

CLAUDE_VERSION=$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')
ID=exitconfirm$$
SESSION=fm-exit-confirm-$$
SLEEP_SECS=917
LAB=

lt() {  # tmux on the lab's dedicated server, never the caller's
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB" tmux "$@"
}

cleanup() {
  [ -n "$LAB" ] || return 0
  lt kill-server >/dev/null 2>&1 || true
  pkill -f "sleep $SLEEP_SECS" >/dev/null 2>&1 || true
  git -C "$LAB/project" worktree remove --force "$LAB/wt" >/dev/null 2>&1 || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

pane() {
  lt capture-pane -p -t "$SESSION:fm-$ID" -S -60 2>/dev/null || true
}

wait_pane() {  # <seconds> <grep -E pattern>: poll the pane for a rendered signal
  local secs=$1 pattern=$2 i=0
  while [ "$i" -lt "$secs" ]; do
    pane | grep -Eq "$pattern" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-exit-confirm.XXXXXX") || fail "could not create the lab"
LAB=$(cd "$LAB" && pwd -P)
mkdir -p "$LAB/home/state" "$LAB/home/data/$ID" "$LAB/project"
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" config user.email 'exit-confirm-test@example.invalid'
git -C "$LAB/project" config user.name 'exit confirm test'
printf 'exit-confirm probe\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" commit -qm 'fixture: exit-confirm probe'
git -C "$LAB/project" worktree add -q "$LAB/wt" -b probe
"$ROOT/bin/fm-claude-trust.sh" "$LAB/wt" "$LAB/project" >/dev/null \
  || fail "could not pre-register workspace trust for the probe worktree"
printf '# probe brief\n' > "$LAB/home/data/$ID/brief.md"
cat > "$LAB/home/state/$ID.meta" <<META
window=$SESSION:fm-$ID
endpoint_task_id=$ID
worktree=$LAB/wt
project=$LAB/project
harness=claude
kind=scout
mode=no-mistakes
yolo=off
model=default
effort=default
META

# A shell hosts the harness, exactly as a spawn's window does, so the endpoint
# survives the exit and the stop can be classified as `dead` rather than
# `missing`.
lt new-session -d -s "$SESSION" -n "fm-$ID" -x 120 -y 40 -c "$LAB/wt" \
  || fail "could not create the lab's tmux server"
lt send-keys -t "$SESSION:fm-$ID" -l "cd '$LAB/wt' && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions"
lt send-keys -t "$SESSION:fm-$ID" Enter

wait_pane 60 'bypass permissions on|❯' || fail "Claude Code $CLAUDE_VERSION did not reach its composer:"$'\n'"$(pane)"
if pane | grep -Eq 'trust this folder|Bypass Permissions mode'; then
  fail "Claude Code $CLAUDE_VERSION opened a startup dialog the probe cannot answer:"$'\n'"$(pane)"
fi

lt send-keys -t "$SESSION:fm-$ID" -l "Run the shell command 'sleep $SLEEP_SECS' as a background task (run_in_background). Do not wait for it. Then reply with one word and stop."
sleep 0.5
lt send-keys -t "$SESSION:fm-$ID" Enter
# The structural signal first: the background shell's own process, which no
# echoed prompt text can fake. Then the idle footer that Claude renders only
# with a live background shell, so the exit command lands on an idle composer.
i=0
until pgrep -f "sleep $SLEEP_SECS" >/dev/null; do
  [ "$i" -lt 120 ] || fail "Claude Code $CLAUDE_VERSION did not start the background shell:"$'\n'"$(pane)"
  sleep 1
  i=$((i + 1))
done
wait_pane 60 'bypass permissions on · [0-9]+ shell' \
  || fail "Claude Code $CLAUDE_VERSION did not return to an idle composer showing its background shell:"$'\n'"$(pane)"

# The rendering proof: raise the dialog by hand, classify the REAL pane through
# the contract the control plane uses, and check the documented Escape
# behaviour (cancel back to the composer, shell still running) before the
# control plane is asked to finish the exit for real.
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
lt send-keys -t "$SESSION:fm-$ID" -l "/exit"
sleep 1.2
lt send-keys -t "$SESSION:fm-$ID" Enter
wait_pane 15 'Background work is running|will stop when you exit|Exit and stop tasks' \
  || fail "Claude Code $CLAUDE_VERSION raised no exit-confirmation dialog for a live background shell:"$'\n'"$(pane)"
VERDICT=$(fm_control_exit_confirm_dialog claude "$(pane)")
[ "$VERDICT" = confirm ] \
  || fail "Claude Code $CLAUDE_VERSION renders its exit dialog in a shape the control plane reads as '${VERDICT:-no dialog}' rather than confirm:"$'\n'"$(pane)"
pass "Claude Code $CLAUDE_VERSION: the exit-confirmation dialog renders with its selection on an exit-confirming option"
lt send-keys -t "$SESSION:fm-$ID" Escape
wait_pane 15 'bypass permissions on · [0-9]+ shell' \
  || fail "Escape did not cancel the exit dialog back to the composer on Claude Code $CLAUDE_VERSION:"$'\n'"$(pane)"
pgrep -f "sleep $SLEEP_SECS" >/dev/null \
  || fail "the background shell did not survive a cancelled exit dialog on Claude Code $CLAUDE_VERSION"
pass "Claude Code $CLAUDE_VERSION: Escape cancels the exit dialog and keeps the background shell"

OUT=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB" FM_HOME="$LAB/home" \
  "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "fm-control exit did not finish on Claude Code $CLAUDE_VERSION (rc=$RC): $OUT"$'\n'"$(pane)"
case "$OUT" in
  "stopped $ID "*) ;;
  *) fail "fm-control exit reported '$OUT' rather than a stop on Claude Code $CLAUDE_VERSION" ;;
esac
CMD=$(lt display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}' 2>/dev/null || true)
case "$CMD" in
  *sh) ;;
  *) fail "the pane still runs '$CMD' after the confirmed exit on Claude Code $CLAUDE_VERSION" ;;
esac
if pgrep -f "sleep $SLEEP_SECS" >/dev/null; then
  fail "the background shell survived the confirmed exit on Claude Code $CLAUDE_VERSION"
fi
pass "Claude Code $CLAUDE_VERSION: fm-control exit confirms the background-work dialog and the agent stops"
