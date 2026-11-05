#!/usr/bin/env bash
# fm-claude-rc-archive.sh - archive the Claude Remote Control session entries a
# torn-down Claude task leaves behind, so finished workers stop lingering in
# the Claude app's session list.
#
# Claude Code archives its own Remote Control session when it exits cleanly
# (SIGHUP, /exit), but not when it is killed: teardown's process reap sends
# TERM and then KILL to everything in the task worktree before it closes the
# pane, and a Claude killed before its archive request finishes leaves its
# entry listed as idle forever. bin/fm-teardown.sh therefore runs `find`
# before it stops the task and `archive` after the endpoint is closed.
# docs/verification/runtime-backends.md "Claude Remote Control archive" holds
# the verified API behavior.
#
# Usage:
#   fm-claude-rc-archive.sh find <task-id> <launch-dir> [<account>]
#     Print one "<claude-dir><TAB><session id>" line per Claude session record
#     (<claude-dir>/sessions/<pid>.json) whose name is <task-id> or the older
#     "<kind>: <task-id>" form bin/fm-spawn.sh gave launches, whose cwd is
#     <launch-dir> (the task worktree, or a secondmate's home), and which
#     carries a bridgeSessionId. Both the name and the launch directory must
#     match, so no other task's or the captain's session is ever named. Live
#     and dead pids both count: a killed Claude leaves its record behind, and
#     that record is exactly the entry still listed. Candidate roots, as in
#     bin/fm-progress.sh: the task's meta account= (`ordinary` is
#     $HOME/.claude), this process's CLAUDE_CONFIG_DIR, and $HOME/.claude.
#     Prints nothing when nothing matches; always exits 0 on a valid request.
#   fm-claude-rc-archive.sh archive [<task-id>]
#     Read find's lines on stdin and archive each session with
#     POST <api>/v1/code/sessions/cse_<id>/archive, the request Claude Code
#     itself sends, authorized by the OAuth access token stored in that root's
#     .credentials.json. HTTP 200, or 409 (already archived), is success.
#     Best effort: each failure - no stored token (a macOS Keychain login), no
#     curl, a refused or timed-out request - prints one `warning:` line to
#     stderr, and the command still exits 0, so a caller never blocks on it.
#     The token travels on curl's stdin config, never on a command line.
#
# Environment:
#   FM_CLAUDE_RC_API_BASE   API origin (default https://api.anthropic.com)
#   FM_CLAUDE_RC_TIMEOUT    per-request ceiling in whole seconds, at least 1 (default 10)
#
# Exit 0 on success or best-effort failure, 2 on a usage error.
set -u

API_BASE=${FM_CLAUDE_RC_API_BASE:-https://api.anthropic.com}
TIMEOUT=${FM_CLAUDE_RC_TIMEOUT:-10}
case "$TIMEOUT" in ''|*[!0-9]*|0*) TIMEOUT=10 ;; esac

usage() {
  sed -n '/^# Usage:/,/^# Exit /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

physical_dir() {  # <dir>: its physical path, or empty when it cannot be resolved
  (cd -P -- "$1" 2>/dev/null && pwd -P) || true
}

cmd_find() {
  local id=${1:-} launch=${2:-} account=${3:-} launch_phys d dirs=() seen=' ' f
  if [ -z "$id" ] || [ -z "$launch" ]; then
    usage >&2
    return 2
  fi
  command -v jq >/dev/null 2>&1 || return 0
  launch_phys=$(physical_dir "$launch")
  case "$account" in
    ordinary) dirs+=("$HOME/.claude") ;;
    /*) dirs+=("$account") ;;
  esac
  dirs+=("${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude")
  for d in "${dirs[@]}"; do
    [ -n "$d" ] && [ -d "$d/sessions" ] || continue
    d=$(physical_dir "$d")
    [ -n "$d" ] || continue
    case "$seen" in *" $d "*) continue ;; esac
    seen+="$d "
    for f in "$d"/sessions/*.json; do
      [ -f "$f" ] || continue
      jq -r --arg id "$id" --arg l "$launch" --arg lp "$launch_phys" --arg d "$d" '
        select(type == "object"
               and ((.name == $id) or ((.name | type) == "string" and (.name | endswith(": " + $id))))
               and ((.cwd == $l) or ($lp != "" and .cwd == $lp))
               and ((.bridgeSessionId | type) == "string"))
        | [$d, .bridgeSessionId] | @tsv' "$f" 2>/dev/null || true
    done
  done | sort -u
  return 0
}

archive_one() {  # <claude-dir> <session-id> <label>
  local dir=$1 sid=$2 label=$3 cse token code
  case "$sid" in
    session_*) cse=cse_${sid#session_} ;;
    cse_*) cse=$sid ;;
    *) cse='' ;;
  esac
  case "${cse#cse_}" in ''|*[!A-Za-z0-9]*) cse='' ;; esac
  if [ -z "$cse" ]; then
    echo "warning: not archiving Claude Remote Control session '$sid'$label: not a session id" >&2
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "warning: could not archive Claude Remote Control session $sid$label: curl is not installed" >&2
    return 0
  fi
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$dir/.credentials.json" 2>/dev/null) || token=''
  case "$token" in ''|*[!A-Za-z0-9_.~+/=-]*)
    echo "warning: could not archive Claude Remote Control session $sid$label: no stored OAuth token in $dir" >&2
    return 0 ;;
  esac
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS -o /dev/null -w '%{http_code}' --config - \
        --connect-timeout 5 --max-time "$TIMEOUT" -X POST \
        -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
        --data '{}' "$API_BASE/v1/code/sessions/$cse/archive" 2>/dev/null) || true
  case "$code" in
    200|409) echo "archived Claude Remote Control session $sid$label" >&2 ;;
    *) echo "warning: could not archive Claude Remote Control session $sid$label: HTTP ${code:-000}" >&2 ;;
  esac
  return 0
}

cmd_archive() {
  local label='' dir sid
  [ -z "${1:-}" ] || label=" for $1"
  command -v jq >/dev/null 2>&1 || {
    echo "warning: could not archive Claude Remote Control sessions$label: jq is not installed" >&2
    return 0
  }
  while IFS=$'\t' read -r dir sid; do
    [ -n "$dir" ] && [ -n "$sid" ] || continue
    archive_one "$dir" "$sid" "$label"
  done
  return 0
}

case "${1:-}" in
  find) shift; cmd_find "$@" ;;
  archive) shift; cmd_archive "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
