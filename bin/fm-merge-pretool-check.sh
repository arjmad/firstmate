#!/usr/bin/env bash
# Stable PreToolUse transport for the merge-guard command policy.
#
# bin/fm-pr-merge.sh owns the current-head, green-check, and merge-authority
# guards for landing a PR. A raw `gh pr merge`, `gh-axi pr merge`, or `gh api`
# merge call typed into a PRIMARY firstmate shell skips all of them. This
# seatbelt denies such a command before it runs.
# bin/fm-merge-command-policy.mjs is the sole owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs. This
# wrapper only scopes the guard to a primary home, acquires the harness payload,
# invokes that policy, and renders the established harness responses. It never
# executes, sources, evaluates, or expands the command.
# See docs/merge-guard.md for the complete contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-merge-pretool-check.sh
#   bin/fm-merge-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude, Codex, and Cursor. CLI mode is used by OpenCode, Pi, and omp after
# their adapters extract the exact command string. --cursor selects Cursor's own
# deny rendering and marks this invocation as the Cursor registration rather
# than the Claude-settings duplicate Cursor also loads.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout.
#   INERT - not a primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Scope is bin/fm-primary-scope-lib.sh's fm_primary_root_matches, the same
# primary-home predicate the turn-end guard uses: a plain firstmate checkout or
# a genuinely marked secondmate home, never a linked crewmate/scout worktree,
# where workers and bin/fm-pr-merge.sh itself keep calling gh.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-merge-pretool-check.sh [--command <cmd>] [--claude|--cursor]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex/Cursor tool_input.command).
Fires only in a primary firstmate home (a plain checkout or a marked secondmate
home); it is a silent no-op in a crewmate/scout task worktree or any
non-firstmate repo.
Exits 0 to allow and 2 to deny a raw gh/gh-axi PR merge that bypasses
bin/fm-pr-merge.sh.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh" 2>/dev/null || exit 0
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Every merge shape the policy denies carries `merge` or `Merge`
# (pr merge, the REST merge endpoint, mergePullRequest,
# enablePullRequestAutoMerge) or enqueuePullRequest in a command word or
# argument, so strip the syntax bytes the classifier joins within a shell word
# and fast-allow anything without them. This substring set is COUPLED to the
# policy's merge shapes: a new denied shape must keep it a strict superset. A
# quoting-decoder marker ($' ANSI-C or $" locale) delegates too, because the
# classifier decodes those and can reconstruct bytes this substring test cannot
# see. This marker set is COUPLED to the classifier's decoder set in
# bin/fm-arm-command-policy.mjs, exactly as bin/fm-cd-pretool-check.sh's is.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *[Mm]erge*|*enqueuePullRequest*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0

# Any failure to confirm a primary home is inert (exit 0), never a block, so a
# broken environment never denies a shell command.
command -v git >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || exit 0
fm_primary_root_matches "$FM_ROOT" || exit 0

POLICY="$FM_ROOT/bin/fm-merge-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
if [ "$CURSOR_MODE" -eq 1 ]; then
  printf '{"permission":"deny","user_message":"%s"}\n' "$ESCAPED"
  exit 0
fi
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
