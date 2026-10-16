#!/usr/bin/env bash
# fm-question-keeper.sh - keeps a Claude primary's supervision running while a
# captain question holds its turn open (docs/supervision-host.md "While a
# captain question is open").
#
# Registered in tracked .claude/settings.json as an asyncRewake PreToolUse hook
# on the AskUserQuestion matcher, beside bin/fm-question-pretool-check.sh,
# whose allow decision it shares through bin/fm-question-lib.sh. Claude runs
# it in the background as a child of the session, so the supervision host it
# runs keeps the session ancestry that proves it owns the fleet lock, and
# Claude holds its exit-2 rewake until the question closes, then delivers it
# into the same turn (docs/verification/supervision.md records both on Claude
# Code 2.1.300).
#
# While the question is open it:
#   - writes state/.question-open naming itself, so every supervision host -
#     the Stop hook's park that kept running from the turn before, or one this
#     keeper starts - holds each close it would hand to main
#     (state/.question-held) and stays parked instead of ending its park;
#   - runs bin/fm-supervision-host.sh park itself whenever no live host is
#     recorded and the away daemon's flag is absent, so the host's engine keeps
#     taking the wakes the supervision branch may take;
#   - watches the session transcript for the question's tool result, which
#     Claude writes both when the captain answers and when he cancels.
# When the question closes it removes the open record, stamps the captain's
# presence (state/.question-answered), asks its own host to hand its watcher
# cycle to the next park (SIGUSR1) and waits for it, then takes every held
# close. A held close exits 2 with one rewake banner listing it, so main drains
# and handles it in the turn it is already in; nothing held exits 0 silently.
# The keeper ends its watch at FM_QUESTION_KEEPER_SECONDS (default 27000,
# under the tracked 28800-second registration) as the host ends its park, and
# delivers what it holds the same way.
#
# It is inert (exit 0, no output, no record) unless the tool blocks, the hook
# runs in a genuine primary checkout whose fleet needs supervision, this
# session holds the fleet lock, a keeper can run here (fm_question_keepable),
# and the guard allows the question: FM_ALLOW_QUESTION_TOOL=1 or a present
# captain.
#
# The hook passes no arguments, so any argument means a manual run: -h or
# --help prints usage and an unknown argument is refused.
set -u

usage() {
  cat <<'EOF'
Usage: fm-question-keeper.sh

Claude asyncRewake PreToolUse hook on AskUserQuestion, registered in
.claude/settings.json; not for manual use. It reads the PreToolUse payload on
stdin and, while the question is open in a primary home that needs
supervision, keeps the supervision host parked and holds every close for main
until the question closes. Exit 0 is silent; exit 2 carries the held closes on
stderr.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // empty)' 2>/dev/null) || exit 0
TOOL_ID=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_use_id // empty)' 2>/dev/null) || exit 0
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '(.transcript_path // empty)' 2>/dev/null) || exit 0
[ -n "$TOOL" ] && [ -n "$TOOL_ID" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

# shellcheck source=bin/fm-question-lib.sh
. "$SCRIPT_DIR/fm-question-lib.sh"
fm_question_tool_blocks "$TOOL" || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
fm_supervision_needed "$STATE" || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
fm_session_lock_owned_by_self "$STATE" || exit 0
fm_question_keepable "$STATE" "$CONFIG" "$TRANSCRIPT" || exit 0
[ "${FM_ALLOW_QUESTION_TOOL:-}" = 1 ] || fm_question_captain_present "$STATE" "$SCRIPT_DIR" || exit 0

numeric_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
BOUND=$(numeric_or "${FM_QUESTION_KEEPER_SECONDS:-}" 27000)
[ "$BOUND" -lt 28800 ] 2>/dev/null || BOUND=27000
POLL=$(numeric_or "${FM_QUESTION_KEEPER_POLL:-}" 1)
# A host that keeps dying is not restarted past this many times.
PARK_FAILURES_MAX=3
HOST_RECORD="$STATE/.supervision-host"

HOST_CHILD=
HOST_OUT=
PENDING=
PARK_FAILURES=0
NEXT_PARK=0
CLOSED=0

# A live host other than this keeper's own child is recorded.
foreign_host_live() {
  local role pid identity
  [ -f "$HOST_RECORD" ] || return 1
  while IFS="$(printf '\t')" read -r role pid identity; do
    [ "$role" = host ] || continue
    [ "$pid" != "$HOST_CHILD" ] || continue
    fm_pid_alive "$pid" && [ -n "$identity" ] && [ "$(_fm_engine_identity "$pid")" = "$identity" ] && return 0
  done < "$HOST_RECORD"
  return 1
}

start_host() {
  local remaining=$1
  HOST_OUT=$(mktemp "$STATE/.question-keeper-host.XXXXXX") || return 1
  # Every arm in a group of its own, so the cycle a hand-over leaves running
  # outlives the teardown of this hook's group after its rewake.
  env -u FM_SUPERVISION_HOST_AUTOARM_GEN -u FM_SUPERVISION_HOST_OWNER_PID -u FM_WATCH_PREDECESSOR_ARM_PID \
    FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_ARM_OWN_GROUP=1 \
    FM_SUPERVISION_HOST_PARK_SECONDS="$remaining" \
    "$SCRIPT_DIR/fm-supervision-host.sh" park > "$HOST_OUT" 2>&1 < /dev/null &
  HOST_CHILD=$!
}

# Reap this keeper's host and keep any close it printed for main.
reap_host() {
  local rc=0 text
  wait "$HOST_CHILD" 2>/dev/null || rc=$?
  text=$(grep -E '^(signal:|stale:|check:|heartbeat|supervision-host:)' "$HOST_OUT" 2>/dev/null || true)
  if [ "$rc" -gt 128 ] || [ ! -s "$HOST_OUT" ]; then
    PARK_FAILURES=$((PARK_FAILURES + 1))
  elif grep -q '^supervision-host stood down: this session no longer owns supervision' "$HOST_OUT" 2>/dev/null; then
    PARK_FAILURES=$PARK_FAILURES_MAX
  fi
  [ -z "$text" ] || PENDING=${PENDING:+$PENDING$'\n'}$text
  rm -f "$HOST_OUT" 2>/dev/null || true
  HOST_CHILD=
  HOST_OUT=
  # A host that ended its park is restarted after a pause, never in a spin.
  NEXT_PARK=$((SECONDS + 5))
}

# shellcheck disable=SC2329 # Invoked by the signal traps.
abandon() {
  trap - HUP TERM INT
  [ -z "$HOST_CHILD" ] || kill -TERM "$HOST_CHILD" 2>/dev/null || true
  [ -z "$HOST_CHILD" ] || wait "$HOST_CHILD" 2>/dev/null || true
  [ -z "$HOST_OUT" ] || rm -f "$HOST_OUT" 2>/dev/null || true
  fm_question_open_clear "$STATE"
  exit 0
}
trap abandon HUP TERM INT

fm_question_open_write "$STATE" "$TOOL_ID" || exit 0
STARTED=$SECONDS
while :; do
  if fm_question_closed "$TRANSCRIPT" "$TOOL_ID"; then
    CLOSED=1
    break
  fi
  [ $((SECONDS - STARTED)) -lt "$BOUND" ] || break
  if [ -n "$HOST_CHILD" ]; then
    fm_pid_alive "$HOST_CHILD" || reap_host
  elif [ "$PARK_FAILURES" -lt "$PARK_FAILURES_MAX" ] && [ "$SECONDS" -ge "$NEXT_PARK" ] \
    && [ ! -e "$STATE/.afk" ] && ! foreign_host_live; then
    start_host $(( BOUND - (SECONDS - STARTED) )) || PARK_FAILURES=$PARK_FAILURES_MAX
  fi
  sleep "$POLL"
done

fm_question_open_clear "$STATE"
[ "$CLOSED" -eq 0 ] || fm_question_answered_stamp "$STATE" || true
if [ -n "$HOST_CHILD" ]; then
  # The hand-over waits for an engine turn already under way to finish; a
  # close that turn hands to main is held, so it is delivered below.
  kill -USR1 "$HOST_CHILD" 2>/dev/null || true
  reap_host
fi
trap - HUP TERM INT

HELD=$(fm_question_hold_take "$STATE" || true)
LINES=$(printf '%s\n%s\n' "$HELD" "$PENDING" | grep -E '^(signal:|stale:|check:|heartbeat|supervision-host:)' | awk '!seen[$0]++' || true)
[ -n "$LINES" ] || exit 0
{
  if [ "$CLOSED" -eq 1 ]; then
    printf 'firstmate watcher wake - not a block on your question: while the captain'"'"'s question was open, supervision kept running and held these events for main; they need a handling turn now.\n'
  else
    printf 'firstmate watcher wake - not a block on your question: the question is still open, but its keeper reached its bound, so these events it held for main need a handling turn now and supervision re-arms at this turn'"'"'s end.\n'
  fi
  printf '%s\n' "$LINES" | awk '/^supervision-host:/ { print; next } shown++ < 8'
  printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. When this turn ends, the Stop hook arms the next cycle automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
} >&2
exit 2
