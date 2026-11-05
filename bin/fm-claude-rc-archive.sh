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
#     Each root is read once and printed as first written, because that is
#     the CLAUDE_CONFIG_DIR a pinned worker ran with and the string Claude
#     Code hashes into the root's keychain service name.
#     Prints nothing when nothing matches; always exits 0 on a valid request.
#   fm-claude-rc-archive.sh archive [<task-id>]
#     Read find's lines on stdin and archive each session with
#     POST <api>/v1/code/sessions/cse_<id>/archive, the request Claude Code
#     itself sends, authorized by that root's stored OAuth access token, read
#     from the stores Claude Code itself reads, in its order: where the macOS
#     `security` tool exists, the login-keychain item Claude Code keys to the
#     root ("Claude Code-credentials" for $HOME/.claude, with a
#     "-<first 8 hex of sha256(root)>" suffix for a set CLAUDE_CONFIG_DIR),
#     then <root>/.credentials.json, its plaintext store on Linux and its
#     fallback on macOS, which a running Claude leaves stale once the keychain
#     holds its login. The first token valid for at least another minute
#     wins, and no later store is read; an expired one is never sent.
#     HTTP 200, or 409 (already archived), is success.
#     Best effort: each failure - no stored token, only expired ones, no
#     curl, a refused or timed-out request - prints one `warning:` line to
#     stderr, and the command still exits 0, so a caller never blocks on it.
#     The token travels on curl's stdin config, never on a command line.
#
# Sourcing this file (in a subshell: it sets `set -u`, its globals, and its
# helper functions) defines rc_token without dispatching a command, so a live
# guard authorizes its own API calls with the same token the helper sends.
#
# Environment:
#   FM_CLAUDE_RC_API_BASE   API origin (default https://api.anthropic.com)
#   FM_CLAUDE_RC_TIMEOUT    per-request ceiling in whole seconds, at least 1 (default 10);
#                           also bounds each keychain read
#
# Exit 0 on success or best-effort failure, 2 on a usage error.
set -u

# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

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
  local id=${1:-} launch=${2:-} account=${3:-} launch_phys d phys dirs=() seen=' ' f
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
    phys=$(physical_dir "$d")
    [ -n "$phys" ] || continue
    case "$seen" in *" $phys "*) continue ;; esac
    seen+="$phys "
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

keychain_services() {  # <claude-dir>: the keychain service names Claude Code may key to it
  local dir=$1 base='Claude Code-credentials' phys d hash
  phys=$(physical_dir "$dir")
  [ "$phys" != "$(physical_dir "$HOME/.claude")" ] || printf '%s\n' "$base"
  for d in "$dir" "${CLAUDE_CONFIG_DIR:-}"; do
    [ -n "$d" ] || continue
    [ "$d" = "$dir" ] || [ "$(physical_dir "$d")" = "$phys" ] || continue
    if command -v shasum >/dev/null 2>&1; then
      hash=$(printf '%s' "$d" | shasum -a 256)
    elif command -v sha256sum >/dev/null 2>&1; then
      hash=$(printf '%s' "$d" | sha256sum)
    else
      continue
    fi
    printf '%s-%s\n' "$base" "${hash:0:8}"
  done | awk '!seen[$0]++'
}

keychain_account() {  # Claude Code's keychain account: $USER, or its fallback name
  local user=${USER:-}
  [ -n "$user" ] || user=$(id -un 2>/dev/null) || user=''
  case "$user" in ''|*[!A-Za-z0-9._-]*) user=claude-code-user ;; esac
  printf '%s\n' "$user"
}

# rc_token <claude-dir>: set RC_TOKEN to the first stored OAuth access token
# for that root still valid for a minute, keychain before .credentials.json,
# reading no further store once one is found, or set it empty and
# RC_TOKEN_PROBLEM to why. Never prints the token.
rc_token() {
  local dir=$1 svc account doc rc now expired='' locked=''
  RC_TOKEN='' RC_TOKEN_PROBLEM="no stored OAuth token in $dir"
  now=$(date +%s)
  if command -v security >/dev/null 2>&1; then
    account=$(keychain_account)
    while IFS= read -r svc; do
      doc=$(fm_run_timed "$TIMEOUT" security find-generic-password -a "$account" -w -s "$svc" 2>/dev/null) && rc=0 || rc=$?
      [ "$rc" != 36 ] || locked=1
      [ "$rc" = 0 ] || continue
      rc_token_take "$doc" && return 0
    done < <(keychain_services "$dir")
  fi
  doc=$(cat "$dir/.credentials.json" 2>/dev/null) || doc=''
  rc_token_take "$doc" && return 0
  [ -z "$expired" ] \
    || RC_TOKEN_PROBLEM="the stored OAuth token for $dir expired at $(jq -rn --argjson e "$expired" '$e / 1000 | floor | todate')"
  [ -z "$locked" ] \
    || RC_TOKEN_PROBLEM+="; the login keychain could not be read here (security exit 36: run outside the macOS Aqua login session)"
  return 0
}

rc_token_take() {  # <credentials json>: one store's check, using rc_token's now and expired
  local row tok exp
  [ -n "$1" ] || return 1
  row=$(printf '%s\n' "$1" | jq -r '.claudeAiOauth // empty
    | select((.accessToken | type) == "string")
    | [.accessToken, ((.expiresAt // "") | tostring)] | @tsv' 2>/dev/null) || row=''
  tok=${row%%$'\t'*} exp=${row#*$'\t'}
  case "$tok" in ''|*[!A-Za-z0-9_.~+/=-]*) return 1 ;; esac
  case "$exp" in
    '') ;;
    *[!0-9]*) return 1 ;;
    *) if [ "$((exp / 1000))" -le "$((now + 60))" ]; then
         [ -n "$expired" ] || expired=$exp
         return 1
       fi ;;
  esac
  RC_TOKEN=$tok
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
  rc_token "$dir"
  token=$RC_TOKEN
  if [ -z "$token" ]; then
    echo "warning: could not archive Claude Remote Control session $sid$label: $RC_TOKEN_PROBLEM" >&2
    return 0
  fi
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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    find) shift; cmd_find "$@" ;;
    archive) shift; cmd_archive "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
fi
