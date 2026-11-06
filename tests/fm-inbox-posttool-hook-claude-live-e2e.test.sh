#!/usr/bin/env bash
# Opt-in real-Claude guard for the steering-inbox PostToolUse hook.
#
# bin/fm-inbox-posttool-hook.sh tells a busy Claude task worker that a steer is
# waiting by printing Claude Code's PostToolUse JSON with
# hookSpecificOutput.additionalContext. tests/fm-busy-adapter-wiring.test.sh
# pins the hook and its spawn wiring against hand-written payloads; this guard
# proves the installed Claude Code still runs the hook after a tool call with
# the session_id the hook's session guard reads, and still hands the context to
# the model, by running the real harness headless and asking the model to quote
# the note it was given. It submits a prompt, so it is opt-in:
# FM_CLAUDE_INBOX_HOOK_LIVE=1 (or FM_LIVE=1). A failure names the Claude Code
# version.
#
# Isolation: a throwaway lab holds the state directory and the working
# directory, and the hooks ride --settings, so no fleet home, project, or user
# setting is touched. The hook commands are the busy writer's session binding
# and the inbox hook, as bin/fm-spawn.sh installs them for a crewmate.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_INBOX_HOOK_LIVE claude jq
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk 'NR == 1 {print $1}')
ID=inboxhook$$
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-hook-live.XXXXXX")
trap 'rm -rf -- "$LAB"' EXIT
mkdir -p "$LAB/state" "$LAB/work"

gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$ID") || fail "could not arm the busy contract"
rec=$(FM_STATE_OVERRIDE="$LAB/state" bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "live steer"' _ \
  "$ROOT/bin/fm-task-inbox-lib.sh" "$LAB/state" "$ID") || fail "could not enqueue a steer"
jq -n \
  --arg sub "'$ROOT/bin/fm-busy-event.sh' apply '$LAB/state' $ID busy --gen $gen --source claude-hook --session-from-payload --event user-prompt-submit 2>/dev/null || true" \
  --arg post "'$ROOT/bin/fm-inbox-posttool-hook.sh' '$LAB/state' $ID --gen $gen 2>/dev/null || true" \
  '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $sub}]}], PostToolUse: [{hooks: [{type: "command", command: $post}]}]}}' \
  > "$LAB/settings.json" || fail "could not write the hook settings"

answer=$(cd "$LAB/work" && timeout 300 claude -p --model haiku --settings "$LAB/settings.json" \
  --allowedTools 'Bash(echo:*)' --output-format json \
  'Run the Bash command `echo one`. Then reply with only the exact file path named by any note that appeared beside the tool result, or NONE if no note appeared. Do not read or move any file.' \
  2>"$LAB/claude.err" | jq -r '.result // empty') || answer=
[ "$(cat "$LAB/state/$ID.inbox/.hook-announced" 2>/dev/null)" = 1 ] \
  || fail "Claude Code $CLAUDE_VERSION did not run the inbox hook for its bound session after a tool call: $(cat "$LAB/claude.err")"
case "$answer" in
  *"$rec"*) ;;
  *) fail "Claude Code $CLAUDE_VERSION did not hand the hook's additionalContext to the model; it answered: $answer" ;;
esac
[ -f "$rec" ] || fail "the announcement must leave the record for the worker to acknowledge"
pass "Claude Code $CLAUDE_VERSION hands the inbox hook's waiting-steer note to the model after a tool call"
