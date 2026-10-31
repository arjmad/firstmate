#!/usr/bin/env bash
# fm-worker-hook-status.sh - a Claude Code crewmate's own lifecycle hooks
# append its status line, so firstmate reads the cause from the log instead of
# inferring it from a quiet pane.
#
# Subcommands (the three hook ones read the hook's JSON payload on stdin):
#
#   stop-failure <state-dir> <id> --gen G --config <dir>
#       StopFailure: the turn ended on an API error. Appends
#       `blocked: Claude Code turn ended on API error <error>: <message>`.
#       An account or credential error (authentication_failed,
#       oauth_org_not_allowed, account_on_hold, billing_error,
#       cloud_credential_error) only the captain can clear carries
#       `[on=captain]`. Skipped when the newest event already says the same.
#
#   session-end <state-dir> <id> --gen G --config <dir>
#       SessionEnd: the Claude Code process is going away. Appends
#       `blocked: Claude Code session ended (<reason>) before the task reported
#       done or failed`, with `[on=captain]` for reason logout. Skipped for
#       reasons clear and resume (the process keeps running), when the newest
#       event is already done or failed, and when firstmate itself asked for the
#       exit (expect-exit below). Spawn runs it BEFORE the busy writer's own
#       session-end event in one hook command, because that event releases the
#       session binding this check reads.
#
#   idle <state-dir> <id> --gen G --config <dir>
#       Notification idle_prompt: the turn ended about a minute ago and nothing
#       has been typed since. When the newest event is `working:` or
#       `resolved:` (or the log is empty) and no decision is open, appends
#       `paused: idle at the prompt ... no wait declared`, the line firstmate
#       otherwise steers an idle worker into writing so stale wakes stop
#       repeating. Any other newest event already accounts for the quiet and is
#       left alone, which also makes a repeated notification a no-op.
#
#   expect-exit <state-dir> <id>
#       Record that firstmate is about to stop this incarnation itself
#       (bin/fm-control.sh exit, bin/fm-teardown.sh), so its session-end hook
#       writes nothing. Records the armed busy gen and the time; a record for
#       another gen, or older than FM_WORKER_EXIT_EXPECT_SECS (default 600),
#       is ignored. No armed gen means no hook can pass the gen check, so
#       nothing is written and it exits 0.
#
# Every hook subcommand writes only for the incarnation and session it was
# armed for: --gen must equal the armed busy gen (bin/fm-busy-lib.sh), and the
# payload's session_id must equal the bound session in state/<id>.busy-session,
# so a superseded incarnation or a nested `claude` run in the worktree writes
# nothing. The status log is state/<id>.status; the line is stamped
# (status_stamp_line) and, when <config>/fleet-ledger exists, recorded through
# bin/fm-fleet-ledger.sh appended, exactly as a worker's own append is.
#
# Exit codes: 0 written or deliberately skipped; 1 refused (stale gen, bad
# input, write failure); 2 usage; 3 payload session is not the bound session.
# Hook command lines append `|| true`; Claude Code ignores these hooks' exit
# codes in any case.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-worker-hook-status.sh stop-failure|session-end|idle <state-dir> <id> --gen G --config <dir>
  fm-worker-hook-status.sh expect-exit <state-dir> <id>
See the header comment for the full contract.
EOF
  exit "${1:-2}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

CMD=${1:-}
case "$CMD" in
  stop-failure|session-end|idle|expect-exit) shift ;;
  -h|--help) usage 0 2>&1 ;;
  *) usage ;;
esac
STATE=${1:-}
ID=${2:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
shift 2
case "$ID" in *[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
MARKER="$STATE/$ID.exit-expected"
EXPECT_SECS=${FM_WORKER_EXIT_EXPECT_SECS:-600}
case "$EXPECT_SECS" in ''|*[!0-9]*) EXPECT_SECS=600 ;; esac

if [ "$CMD" = expect-exit ]; then
  [ "$#" -eq 0 ] || usage
  gen=$(fm_busy_current_gen "$STATE" "$ID") || exit 0
  tmp="$MARKER.tmp.$$"
  { printf '%s %s\n' "$gen" "$(date +%s)" > "$tmp" && mv -f "$tmp" "$MARKER"; } || {
    rm -f "$tmp"
    echo "error: could not record the expected exit for $ID" >&2
    exit 1
  }
  exit 0
fi

GEN=
CONFIG=
while [ $# -gt 0 ]; do
  case "$1" in
    --gen) GEN=${2:-}; shift 2 || usage ;;
    --config) CONFIG=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
[ -n "$GEN" ] && [ -n "$CONFIG" ] || usage
fm_busy_token_valid "$GEN" || { echo "error: invalid --gen" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required to read the hook payload" >&2; exit 1; }
PAYLOAD=$(cat) || PAYLOAD=
field() {  # <name> -> the payload's string field, empty when absent
  printf '%s' "$PAYLOAD" | jq -r --arg k "$1" 'if type == "object" and (.[$k] | type) == "string" then .[$k] else empty end' 2>/dev/null
}

current=$(fm_busy_current_gen "$STATE" "$ID") || { echo "error: no armed busy-state gen for $ID" >&2; exit 1; }
[ "$GEN" = "$current" ] || { echo "error: stale gen for $ID (hook refused)" >&2; exit 1; }
session=$(field session_id)
fm_busy_token_valid "$session" || { echo "error: hook payload names no valid session_id for $ID" >&2; exit 1; }
bound=
SESSION_FILE=$(fm_busy_session_path "$STATE" "$ID")
if [ -f "$SESSION_FILE" ] && [ ! -L "$SESSION_FILE" ]; then
  IFS= read -r bound < "$SESSION_FILE" 2>/dev/null || bound=
fi
[ "$bound" = "$session" ] || { echo "error: hook for $ID from session $session, not the bound session (refused)" >&2; exit 3; }

STATUS="$STATE/$ID.status"
last=$(last_status_line "$STATUS")
last_verb=
last_untimed=
status_line_verb "$last" last_verb

# One line of payload prose: control bytes become spaces, runs collapse, and
# the result is capped so a long vendor error cannot swamp the log.
one_line() {  # <text> <max-chars>
  local t
  t=$(printf '%s' "$1" | LC_ALL=C tr -s '\000-\037\177' ' ')
  t=${t#"${t%%[![:space:]]*}"}
  t=${t%"${t##*[![:space:]]}"}
  [ "${#t}" -le "$2" ] || t="${t:0:$2}..."
  printf '%s' "$t"
}
token() {  # <value> -> the value when it is a plain lowercase token, else unknown
  case "$1" in ''|*[!a-z0-9_]*) printf 'unknown' ;; *) printf '%s' "$1" ;; esac
}

line=
case "$CMD" in
  stop-failure)
    err=$(token "$(field error)")
    msg=$(one_line "$(field last_assistant_message)" 240)
    [ -n "$msg" ] || msg=$(one_line "$(field error_details)" 240)
    head=blocked
    case "$err" in
      authentication_failed|oauth_org_not_allowed|account_on_hold|billing_error|cloud_credential_error)
        head='blocked [on=captain]' ;;
    esac
    line="$head: Claude Code turn ended on API error $err${msg:+: $msg}; the worker is idle until it is prompted again (StopFailure hook)"
    _fm_status_untimed "$last" last_untimed
    [ "$last_untimed" != "$line" ] || exit 0
    ;;
  session-end)
    reason=$(token "$(field reason)")
    case "$reason" in clear|resume) exit 0 ;; esac
    case "$last_verb" in done|failed) exit 0 ;; esac
    if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
      read -r m_gen m_at _ < "$MARKER" 2>/dev/null || m_gen=
      case "${m_at:-}" in ''|*[!0-9]*) m_at=0 ;; esac
      [ "$m_gen" != "$GEN" ] || [ $(( $(date +%s) - m_at )) -gt "$EXPECT_SECS" ] || exit 0
    fi
    head=blocked
    [ "$reason" != logout ] || head='blocked [on=captain]'
    line="$head: Claude Code session ended ($reason) before the task reported done or failed, so no agent is running for it (SessionEnd hook)"
    ;;
  idle)
    [ "$(field notification_type)" = idle_prompt ] || exit 0
    case "$last_verb" in
      ''|working|"${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}") ;;
      *) exit 0 ;;
    esac
    [ -z "$(status_open_decisions "$STATUS")" ] || exit 0
    line="${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}: idle at the prompt since its turn ended about a minute ago, with no wait declared after its last status (Claude Code idle_prompt hook)"
    ;;
esac

printf '%s\n' "$(status_stamp_line "$line")" >> "$STATUS" || { echo "error: could not append to $STATUS" >&2; exit 1; }
[ ! -e "$CONFIG/fleet-ledger" ] || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATUS" >/dev/null 2>&1 || true
exit 0
