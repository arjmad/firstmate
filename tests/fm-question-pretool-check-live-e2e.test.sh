#!/usr/bin/env bash
# Live guard for the blocking-question guard (bin/fm-question-pretool-check.sh):
# a real interactive Claude runs in a fixture primary checkout carrying this
# repo's tracked AskUserQuestion registration and is asked to call the tool.
# The verdict rests on the tool name Claude sends to the hook, so only the real
# harness can prove it. Opt-in because it submits prompts:
#
#   FM_QUESTION_GUARD_LIVE_E2E=1 tests/fm-question-pretool-check-live-e2e.test.sh
#
# Two structural signals carry the verdict, never rendered text: a recorder
# hook beside the tracked one captures the PreToolUse payload, and a Stop hook
# records each turn end. With work under way the turn must end, because the
# guard denied the question; with an idle home the same request must leave the
# turn open on the selector, so the guard is what ended the first turn.
# An absent Claude is reported and fails the forced run rather than passing.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

fm_live_gate opt-in FM_QUESTION_GUARD_LIVE_E2E jq tmux

LAB=$(fm_test_tmproot fm-question-guard-live)
SOCKET="fmqg-$$"
TARGET=claude

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ALLOW_QUESTION_TOOL TMUX TMUX_PANE

command -v claude >/dev/null 2>&1 || fail "claude is not installed, so the question guard was not checked"
VERSION=$(claude --version 2>/dev/null | head -n 1)

ROOT_LAB="$LAB/primary"
mkdir -p "$ROOT_LAB/state" "$ROOT_LAB/.claude"
git init -q "$ROOT_LAB"
: > "$ROOT_LAB/AGENTS.md"
# Real copies, not a symlink to this checkout's bin: the guard resolves its own
# directory to find its home, and a task worktree is correctly out of scope.
mkdir -p "$ROOT_LAB/bin"
cp "$ROOT/bin/fm-question-pretool-check.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" "$ROOT_LAB/bin/"
cat > "$ROOT_LAB/record-payload.sh" <<'SH'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")" && pwd)
cat >> "$dir/state/payloads.jsonl"
printf '\n' >> "$dir/state/payloads.jsonl"
SH
cat > "$ROOT_LAB/record-stop.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
dir=$(cd "$(dirname "$0")" && pwd)
printf 'stop\n' >> "$dir/state/stops"
SH
chmod +x "$ROOT_LAB/record-payload.sh" "$ROOT_LAB/record-stop.sh"
# Only the tracked question registration, plus the two recorders.
jq '{hooks: {PreToolUse: ([.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("fm-question-pretool-check.sh")))]
      + [{matcher: "AskUserQuestion", hooks: [{type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/record-payload.sh"}]}]),
    Stop: [{hooks: [{type: "command", command: "\"$CLAUDE_PROJECT_DIR\"/record-stop.sh"}]}]}}' \
  "$ROOT/.claude/settings.json" > "$ROOT_LAB/.claude/settings.json"
jq -e '.hooks.PreToolUse | length == 2' "$ROOT_LAB/.claude/settings.json" >/dev/null \
  || fail "the tracked settings carry no AskUserQuestion registration for the guard"

: > "$ROOT_LAB/state/stops"
: > "$ROOT_LAB/state/payloads.jsonl"
stops() { wc -l < "$ROOT_LAB/state/stops" | tr -d ' '; }
asks() { jq -s '[.[] | select(.tool_name == "AskUserQuestion")] | length' "$ROOT_LAB/state/payloads.jsonl"; }
screen_tail() { tmux -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 12; }

claude_ready() {
  local busy composer
  tmux() { command tmux -L "$SOCKET" "$@"; }
  busy=$(fm_pane_busy_state "$TARGET" claude)
  composer=$(fm_tmux_composer_state "$TARGET")
  unset -f tmux
  [ "$busy" = idle ] && [ "$composer" = empty ]
}

wait_ready() {
  local i=0 screen
  while [ "$i" -lt 90 ]; do
    screen=$(tmux -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null)
    case "$screen" in
      *'Yes, I trust this folder'*)
        tmux -L "$SOCKET" send-keys -t "$TARGET" Down; sleep 0.5; tmux -L "$SOCKET" send-keys -t "$TARGET" Enter; sleep 3 ;;
      *'Allow external CLAUDE.md'*) tmux -L "$SOCKET" send-keys -t "$TARGET" Enter; sleep 3 ;;
      *) claude_ready && return 0 ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  fail "claude $VERSION never reached an idle empty composer: $(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -n 6)"
}

submit() {  # <prompt>
  tmux -L "$SOCKET" send-keys -t "$TARGET" -l "$1"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$TARGET" Enter
}

wait_for() {  # <seconds> <command...>: success once the command succeeds
  local limit=$(( $1 * 2 )) i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
asked_more_than() { [ "$(asks)" -gt "$1" ]; }
stopped_more_than() { [ "$(stops)" -gt "$1" ]; }

PROMPT='Call the AskUserQuestion tool now with one question, Pick a color, options Red and Blue. If the call is refused, reply with one short sentence and stop.'

printf 'window=lab\n' > "$ROOT_LAB/state/lab-task.meta"
CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false tmux -L "$SOCKET" new-session -d -s "$TARGET" -x 200 -y 50 -c "$ROOT_LAB" \
  "claude --model haiku --dangerously-skip-permissions" || fail "claude $VERSION: the tmux session did not start"
wait_ready

# Work under way: the question reaches the guard, which denies it, so the turn ends.
before_stops=$(stops)
submit "$PROMPT"
wait_for 180 asked_more_than 0 || fail "claude $VERSION never sent an AskUserQuestion PreToolUse payload to the tracked matcher"
wait_for 180 stopped_more_than "$before_stops" \
  || fail "claude $VERSION: with work under way the turn stayed open after AskUserQuestion, so the guard did not end it: $(screen_tail)"
printf 'ok - claude %s: the tracked matcher received AskUserQuestion and the turn ended with work under way\n' "$VERSION"

# Idle home, the counterfactual: the same request opens the selector and the turn stays open.
rm -f "$ROOT_LAB/state/lab-task.meta"
wait_ready
before_asks=$(asks)
before_stops=$(stops)
submit "$PROMPT"
wait_for 180 asked_more_than "$before_asks" || fail "claude $VERSION never sent the second AskUserQuestion payload"
if wait_for 20 stopped_more_than "$before_stops"; then
  fail "claude $VERSION: the idle-home turn ended too, so this run cannot show the guard ended the first turn"
fi
printf 'ok - claude %s: on an idle home the selector held the turn open, so the deny is what ended the first turn\n' "$VERSION"

pass "question guard live: claude $VERSION honors the tracked AskUserQuestion deny"
