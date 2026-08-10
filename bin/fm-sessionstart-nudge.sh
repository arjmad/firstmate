#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine firstmate
# primary whose current harness session has not already acquired the home lock.
# In --claude mode, an already-owned SessionStart also rebinds the payload's
# session id to the retained home-lock generation before exiting silently. This
# gives later Stop-hook process lanes one stable post-restart identity without
# making the shared nudge acquire the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
# Usage: fm-sessionstart-nudge.sh [--claude]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CLAUDE_MODE=0
case "${1:-}" in
  '') ;;
  --claude) CLAUDE_MODE=1 ;;
  *) exit 0 ;;
esac

PAYLOAD=
CLAUDE_SESSION_ID=
if [ "$CLAUDE_MODE" -eq 1 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1; then
    CLAUDE_SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi
fi

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

if [ "$CLAUDE_MODE" -eq 1 ] && fm_claude_session_id_valid "$CLAUDE_SESSION_ID"; then
  if fm_session_lock_owned_by_self "$STATE"; then
    fm_claude_session_binding_write "$STATE" "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
    rm -f "$STATE/.claude-primary-session.pending" 2>/dev/null || true
    exit 0
  fi
  fm_claude_session_pending_write "$STATE" "$CLAUDE_SESSION_ID" >/dev/null 2>&1 || true
fi
lock_is_in_ancestry && exit 0
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
