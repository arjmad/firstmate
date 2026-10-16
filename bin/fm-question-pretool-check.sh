#!/usr/bin/env bash
# PreToolUse guard against a primary parking its turn on a blocking question.
#
# A blocking question tool, such as Claude Code's AskUserQuestion, holds the
# current turn open until the captain answers. A Claude primary's supervision
# re-arms only at a turn end (the Stop asyncRewake hook,
# bin/fm-claude-stop-autoarm.sh), and a supervision host that handed main a
# wake has already stopped its own cycle, so while the question waits no
# watcher runs and every wake - captain inbox notes, merges, blockers - waits
# behind it. The captain's rule is the opposite: while a question to him is
# unanswered, keep working everything else; only the item that needs his
# answer waits. Asking in the turn's final message and ending the turn keeps
# the Stop-owned cycle running and leaves the answer to arrive as an ordinary
# captain message.
#
# So in a genuine primary home whose fleet needs supervision
# (fm_supervision_needed in bin/fm-supervision-lib.sh), this guard denies the
# known blocking question tools with a reason that names the non-blocking
# route. An idle home, where nothing can park, keeps the tool.
# This script is the single owner of which tool names block; the tracked Claude
# matcher names the same tool so ordinary calls never start this script.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-question-pretool-check.sh [--claude]
#   bin/fm-question-pretool-check.sh --tool '<tool-name>' [--claude]
#
# Stdin mode extracts .tool_name for Claude and Codex, or .toolName for Grok.
#
# Exit/output contract (identical shape to bin/fm-subagent-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo), or a home with no supervision need: exit 0
#           with no output, exactly like ALLOW.
#   ESCAPE - FM_ALLOW_QUESTION_TOOL=1 in the environment allows deliberately.
#   FAIL OPEN - malformed or empty stdin, or missing jq for stdin transport.
#
# Claude requires stdout to remain empty on deny.
set -u

# Exact normalized (lowercase, alphanumeric) names of tools that hold the turn
# open until the captain answers. Extend only with a tool verified to block.
BLOCKING_QUESTION_TOOLS='askuserquestion'

TOOL=""
TOOL_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-question-pretool-check.sh [--tool <tool-name>] [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name, or Grok toolName).
Denies a blocking question tool (Claude's AskUserQuestion) in a genuine
primary home whose fleet needs supervision, because the open question holds
the turn and no wake is handled until the captain answers.
Silent no-op in a crewmate/scout task worktree, a non-firstmate repo, or a
home with nothing to supervise.
Exits 0 to allow and 2 to deny, naming the non-blocking way to ask.
Set FM_ALLOW_QUESTION_TOOL=1 in the session environment to allow deliberately.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
fi

[ -n "$TOOL" ] || exit 0

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

MATCHED=""
for name in $BLOCKING_QUESTION_TOOLS; do
  [ "$NORMALIZED" != "$name" ] || { MATCHED=$name; break; }
done
[ -n "$MATCHED" ] || exit 0

# Like FM_ALLOW_SUBAGENT, an environment variable set at launch, so no
# in-session tool call can release the guard for the call that follows.
[ "${FM_ALLOW_QUESTION_TOOL:-}" != "1" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# A crewmate never addresses the captain, and a non-firstmate repo has no fleet
# to park, so only a genuine primary home (plain checkout or marked secondmate
# home) is in scope. Any failure to confirm the home is inert, never a block.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
fm_supervision_needed "$STATE" || exit 0

REASON="[question-park] $TOOL holds this turn open until the captain answers, and supervision re-arms only when a turn ends, so while it waits no wake is handled and fleet work under way stalls behind it. Instead, put the question in this turn's final message (context, options, your recommendation), hold the item it gates for the captain (AGENTS.md section 10), and end the turn: keep working everything else, and only the item that needs the answer waits (blocked tool: $TOOL). Launch the session with FM_ALLOW_QUESTION_TOOL=1 for a deliberate exception."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
