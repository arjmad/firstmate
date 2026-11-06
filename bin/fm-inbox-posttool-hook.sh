#!/usr/bin/env bash
# fm-inbox-posttool-hook.sh - a Claude Code task worker's PostToolUse hook that
# tells the worker a Firstmate steer is waiting, mid-turn, without typing.
#
# Usage (wired by bin/fm-spawn.sh into a ship or scout worker's hooks; reads
# the hook's JSON payload on stdin):
#
#   fm-inbox-posttool-hook.sh <state-dir> <id> --gen G
#
# The watcher's doorbell never types into a busy pane (bin/fm-task-inbox-lib.sh
# owns that ladder), so a worker inside a long run of tool calls would not see
# a steer until its turn ended. After each completed tool call this hook
# announces every unhandled record in state/<id>.inbox it has not announced
# before, by printing Claude Code's PostToolUse JSON with
# hookSpecificOutput.additionalContext set to one line per record:
#   Firstmate instruction waiting: read <record>, act on it, then mv it into <inbox>/handled/.
# Claude Code adds that context beside the tool result the model reads next.
# bin/fm-task-inbox-lib.sh fm_task_inbox_announce_new owns which records are
# new, so each is announced once; the worker's mv stays the only
# acknowledgement, and the watcher's ladder and busy budget still run as before.
#
# It speaks only for the incarnation and session it was armed for, as
# bin/fm-worker-hook-status.sh does: --gen must equal the armed busy gen
# (bin/fm-busy-lib.sh), and the payload's session_id must equal the bound
# session in state/<id>.busy-session, so a nested `claude` run in the worktree,
# which loads the same hooks, never spends the announcement.
#
# Prints nothing and exits 0 when there is nothing new, the hook is refused, or
# jq is missing; a failure never prints partial output. Exit codes: 0 always
# except 2 usage. The hook command line also appends `|| true`, and PostToolUse
# cannot block a call in any case.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-inbox-posttool-hook.sh <state-dir> <id> --gen G" >&2
  exit 2
}

[ "$#" -eq 4 ] && [ "$3" = --gen ] || usage
STATE=$1
ID=$2
GEN=$4

# Nothing waiting is the common case on every tool call: answer it before
# reading the payload or sourcing anything.
set -- "$STATE/$ID.inbox"/*.msg
[ -e "$1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

fm_busy_token_valid "$GEN" || exit 0
current=$(fm_busy_current_gen "$STATE" "$ID") || exit 0
[ "$GEN" = "$current" ] || exit 0
session=$(jq -r 'if type == "object" and (.session_id | type) == "string" then .session_id else empty end' 2>/dev/null) || session=
fm_busy_token_valid "$session" || exit 0
SESSION_FILE=$(fm_busy_session_path "$STATE" "$ID")
bound=
if [ -f "$SESSION_FILE" ] && [ ! -L "$SESSION_FILE" ]; then
  IFS= read -r bound < "$SESSION_FILE" 2>/dev/null || bound=
fi
[ "$bound" = "$session" ] || exit 0

records=$(fm_task_inbox_announce_new "$STATE" "$ID" 2>/dev/null) || exit 0
[ -n "$records" ] || exit 0
inbox=$(fm_task_inbox_dir "$STATE" "$ID")
context=
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  context="${context:+$context
}Firstmate instruction waiting: read $rec, act on it, then mv it into $inbox/handled/."
done <<EOF
$records
EOF
out=$(jq -cn --arg c "$context" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}') || exit 0
printf '%s\n' "$out"
exit 0
