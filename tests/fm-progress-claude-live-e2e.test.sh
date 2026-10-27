#!/usr/bin/env bash
# Opt-in credentialed live guard for bin/fm-progress.sh's Claude task-list
# source. The reader's step n/m comes from files Claude Code writes, so this
# drives the installed Claude Code for real: an interactive session launched
# the way bin/fm-spawn.sh launches a task worker (CLAUDE_CODE_ENABLE_TODO_TOOLS=1
# and a bare <task-id> --name) builds a three-step task list, and the
# reader, given only a fixture home's task record, must find that session
# record by name and live pid and report 1/3 with the in-progress step.
# It fails naming the Claude Code version when any link in that chain moved.
# One Haiku turn is submitted. Refresh docs/verification/runtime-backends.md
# "Claude task list" from this guard after a Claude Code upgrade.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PROGRESS_CLAUDE_LIVE_E2E claude tmux jq

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-progress-claude-live)
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
SOCKET="fm-progress-claude-$$"
SESSION="fm-progress-claude-e2e"
ID="progress-live-$$"
# The reader looks in the worker's account root, else CLAUDE_CONFIG_DIR, else
# $HOME/.claude; the session runs on this process's own login.
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SID=''

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "$SID" ] || rm -rf "${CLAUDE_DIR:?}/tasks/$SID"
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$HOME_DIR/state"
fm_write_meta "$HOME_DIR/state/$ID.meta" kind=ship harness=claude "project=$PROJECT" \
  "account=$CLAUDE_DIR" "spawn_gen=s$(date +%s).1.2"

# Claude Code refuses to nest inside another Claude session, and a task id or
# inbox inherited from a worker would let this session's hooks write that
# worker's records, so both are dropped from the lab's environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|FM_[A-Z_]+)=' | cut -d= -f1 | sort -u)
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

# The folder-trust dialog opens with its cursor on "No, exit": move onto the
# trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 1 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) tmux -L "$SOCKET" send-keys -t "$SESSION" Enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

PROMPT="Use the TaskCreate tool to create exactly three tasks with subjects 'Alpha step', 'Beta step', and 'Gamma step'. Then use TaskUpdate to mark 'Alpha step' completed and 'Beta step' in_progress. Do nothing else, then reply DONE."
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PROJECT" \
  "env $(unset_inherited) CLAUDE_CONFIG_DIR='$CLAUDE_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 CLAUDE_CODE_ENABLE_TODO_TOOLS=1 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --name '$ID' \"$PROMPT\"; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"

# Poll the reader, answering the trust dialog, until the projection shows the
# list or the iteration budget (about 3 minutes) runs out.
got='' i=0
while [ "$i" -lt 720 ]; do
  shot=$(screen)
  case "$shot" in
    *'CLAUDE_EXIT='*)
      printf '%s\n' "$shot" >&2
      fail "Claude Code $CLAUDE_VERSION exited before the reader saw its task list"
      ;;
  esac
  answer_trust_dialog "$shot" || :
  if [ -z "$SID" ]; then
    SID=$(jq -r --arg n "$ID" 'select(.name == $n) | .sessionId' "$CLAUDE_DIR"/sessions/*.json 2>/dev/null | head -1)
  fi
  got=$(FM_HOME=$HOME_DIR "$ROOT/bin/fm-progress.sh" --json \
    | jq -r '.workers[0].steps | if . == null then "none" else "\(.done)/\(.total)|\(.current)|\(.source)" end')
  [ "$got" = '1/3|Beta step|task-list' ] && break
  sleep 0.25
  i=$((i + 1))
done
if [ "$got" != '1/3|Beta step|task-list' ]; then
  printf '%s\n' "$(screen)" >&2
  [ -z "$SID" ] || ls -la "$CLAUDE_DIR/tasks/$SID" >&2 2>/dev/null
  fail "Claude Code $CLAUDE_VERSION: fm-progress.sh read steps '$got', want '1/3|Beta step|task-list' (session ${SID:-not found})"
fi
pass "Claude Code $CLAUDE_VERSION: a worker launched with CLAUDE_CODE_ENABLE_TODO_TOOLS=1 and --name '<id>' keeps a task list fm-progress.sh reads as 1/3 · Beta step"
