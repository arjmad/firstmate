#!/usr/bin/env bash
# Forced read of a session-start digest that Claude Code cut to a preview.
#
# Why it exists: Claude Code injects SessionStart hook output into context only
# up to a size cap; a larger output is saved to
# `<project>/<session>/tool-results/hook-<uuid>-stdout.txt` and the model sees
# "Output too large ... Full output saved to <path>" over a 2,000-character
# preview. A firstmate digest is far larger than that cap, and its CONTEXT
# section (data/captain.md, data/learnings.md) prints last, so a helm that acts
# on the preview acts without its captain's standing rulings. A read cue at the
# head of the digest was not enough on its own, so this check enforces it: until
# the digest has been read in full, the session may use only the Read tool on
# the digest.
#
# This is a fork patch (docs/fork-decisions/2026-11-07-forced-digest-read.md).
# It is Claude-only: bin/fm-sessionstart-run.sh arms it only when
# .claude/settings.json invokes it with --claude, and only the tracked Claude
# settings register the check and record hooks. Other harnesses keep the cue.
#
# Usage:
#   fm-digest-read-check.sh arm <session-id> <digest-copy>
#       Called by fm-sessionstart-run.sh after it saved the digest it printed.
#       Arms the session when the copy is larger than the spill threshold
#       (FM_DIGEST_SPILL_BYTES, default 10000 characters, Claude Code's hook
#       output cap), replacing any earlier arm of the same session, so a
#       post-compaction re-emit must be read again. Also prunes other sessions'
#       records older than two days. Prints nothing; always exits 0.
#   <PreToolUse JSON on stdin> | fm-digest-read-check.sh check --claude
#       ALLOW (exit 0, no output) when the session is not armed, when the tool
#       is Read on the digest copy or on this session's saved hook output whose
#       first line matches the copy, when FM_ALLOW_UNREAD_DIGEST=1, outside a
#       genuine primary home, and on malformed transport or missing jq.
#       DENY (exit 2, Claude deny object on stderr, stdout empty) otherwise,
#       naming the copy and the lines still unread.
#   <PostToolUse JSON on stdin> | fm-digest-read-check.sh record
#       After a successful Read of an accepted path, records the lines it
#       covered (offset, default 1; limit, default 2000) and disarms the
#       session once every line of the copy is covered. Prints nothing.
#
# State: $STATE/.digest-read/<session-id>.txt is the saved digest and
# $STATE/.digest-read/<session-id>.pending the arm record (one `range S E` line
# per covered read). A missing copy disarms (fail open), so a cleaned state
# directory can never lock a session out of its tools.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DIR="$STATE/.digest-read"
DEFAULT_READ_LIMIT=2000

valid_session() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

line_count() {
  awk 'END { print NR }' "$1" 2>/dev/null
}

spill_threshold() {
  case "${FM_DIGEST_SPILL_BYTES:-}" in
    ''|0*|*[!0-9]*) printf '10000\n' ;;
    *) printf '%s\n' "$FM_DIGEST_SPILL_BYTES" ;;
  esac
}

cmd_arm() {
  local session=${1:-} copy=${2:-} size pending
  valid_session "$session" || return 0
  [ -f "$copy" ] || return 0
  mkdir -p "$DIR" 2>/dev/null || return 0
  find "$DIR" -maxdepth 1 -type f -mtime +2 -exec rm -f {} + 2>/dev/null || true
  pending="$DIR/$session.pending"
  size=$(wc -c < "$copy" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -le "$(spill_threshold)" ]; then
    rm -f "$pending" 2>/dev/null || true
    return 0
  fi
  printf 'copy %s\n' "$copy" > "$pending" 2>/dev/null || true
}

# Prints "<session>\t<tool>\t<file_path>\t<offset>\t<limit>" from a hook payload.
parse_payload() {
  local payload=$1
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -r '
    [ (.session_id // ""), (.tool_name // ""),
      ((.tool_input // {}) | .file_path // ""),
      ((.tool_input // {}) | (.offset // "") | tostring),
      ((.tool_input // {}) | (.limit // "") | tostring) ] | @tsv
  ' 2>/dev/null
}

# accepted_path <session> <copy> <path>: the copy itself, or this session's
# saved hook output whose first line is the copy's first line (the head cue,
# which names this session's copy, so another hook's spill never matches).
accepted_path() {
  local session=$1 copy=$2 path=$3 first_copy first_path
  [ -n "$path" ] || return 1
  [ "$path" = "$copy" ] && return 0
  case "$path" in
    */"$session"/tool-results/hook-*-stdout.txt) ;;
    *) return 1 ;;
  esac
  [ -f "$path" ] || return 1
  first_copy=$(head -n 1 "$copy" 2>/dev/null) || return 1
  first_path=$(head -n 1 "$path" 2>/dev/null) || return 1
  [ -n "$first_copy" ] && [ "$first_copy" = "$first_path" ]
}

# unread_ranges <pending> <total>: the uncovered line ranges, "a-b, c-d".
unread_ranges() {
  awk -v total="$2" '
    $1 == "range" { for (i = $2; i <= $3 && i <= total; i++) seen[i] = 1 }
    END {
      out = ""; start = 0
      for (i = 1; i <= total + 1; i++) {
        if (i <= total && !(i in seen)) { if (!start) start = i; continue }
        if (start) { out = out (out == "" ? "" : ", ") start "-" (i - 1); start = 0 }
      }
      print out
    }
  ' "$1" 2>/dev/null
}

load_arm() {
  # Sets SESSION TOOL FILE_PATH OFFSET LIMIT PENDING COPY; returns 1 when the
  # session is not armed or the payload cannot be read.
  local payload parsed
  payload=$(cat 2>/dev/null || true)
  parsed=$(parse_payload "$payload") || return 1
  IFS=$'\t' read -r SESSION TOOL FILE_PATH OFFSET LIMIT <<EOF_PARSED
$parsed
EOF_PARSED
  valid_session "${SESSION:-}" || return 1
  PENDING="$DIR/$SESSION.pending"
  [ -f "$PENDING" ] || return 1
  COPY=$(awk '$1 == "copy" { sub(/^copy /, ""); print; exit }' "$PENDING" 2>/dev/null)
  if [ -z "$COPY" ] || [ ! -f "$COPY" ]; then
    rm -f "$PENDING" 2>/dev/null || true
    return 1
  fi
  return 0
}

cmd_check() {
  local total unread reason escaped
  [ "${FM_ALLOW_UNREAD_DIGEST:-}" != "1" ] || return 0
  # The arm lookup comes first because it is cheap and this runs on every tool
  # call; the scope check then keeps a linked task worktree inert.
  load_arm || return 0
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  if [ "$TOOL" = Read ] && accepted_path "$SESSION" "$COPY" "$FILE_PATH"; then
    return 0
  fi
  total=$(line_count "$COPY")
  unread=$(unread_ranges "$PENDING" "$total")
  reason="[digest-read] this session's start digest was cut to a preview, so its captain rulings, learnings, and fleet state are not in context yet (AGENTS.md section 3). Read $COPY in full with the Read tool before anything else: $total lines, still unread: ${unread:-none}; read it in offset/limit chunks of about 600 lines when one read is too large. Every other tool is refused until then (blocked tool: ${TOOL:-unknown}). Launch the session with FM_ALLOW_UNREAD_DIGEST=1 for a deliberate exception."
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  exit 2
}

cmd_record() {
  local start limit end total unread
  load_arm || return 0
  [ "$TOOL" = Read ] || return 0
  accepted_path "$SESSION" "$COPY" "$FILE_PATH" || return 0
  case "$OFFSET" in ''|null|*[!0-9]*) start=1 ;; *) start=$OFFSET ;; esac
  [ "$start" -ge 1 ] || start=1
  case "$LIMIT" in ''|null|0|*[!0-9]*) limit=$DEFAULT_READ_LIMIT ;; *) limit=$LIMIT ;; esac
  end=$((start + limit - 1))
  printf 'range %s %s\n' "$start" "$end" >> "$PENDING" 2>/dev/null || return 0
  total=$(line_count "$COPY")
  unread=$(unread_ranges "$PENDING" "$total")
  [ -n "$unread" ] || rm -f "$PENDING" 2>/dev/null || true
  return 0
}

case "${1:-}" in
  arm) shift; cmd_arm "$@"; exit 0 ;;
  check) cmd_check; exit 0 ;;
  record) cmd_record; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 0 ;;
esac
