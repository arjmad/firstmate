#!/usr/bin/env bash
# fm-account-drain.sh - firstmate's half of a two-account Claude drain:
# the helm hands itself over when its launch line moved to another account,
# and Claude workers stop when both accounts are low.
#
# Usage:
#   fm-account-drain.sh check            watcher check: one account-moved line per move
#   fm-account-drain.sh handover         end this helm and start a fresh one on the new account
#   fm-account-drain.sh record-session   record this helm session's account (session start)
#   fm-account-drain.sh both-low         exit 0 and print the spill when both accounts are low
#   fm-account-drain.sh arm | disarm     register or remove state/account-drain.check.sh
#   fm-account-drain.sh --help
#
# OPT-IN. Everything reads config/account-drain (gitignored, home-local), whose
# schema docs/configuration.md "Account drain" owns. With no such file every
# subcommand is a silent no-op (handover and arm say so and exit 1), so a home
# that never configures it gains no behavior and no dependency.
#
# Inputs, all read-only:
#   - config/primary-harness, the launch line bin/firstmate (the fleet's
#     launcher, outside this repository) reads at each helm start: its first
#     meaningful line, leading NAME=value words, then the harness. Its
#     CLAUDE_CONFIG_DIR word names the Claude store the next helm runs on; no
#     such word is the "ordinary" store.
#   - state/.account-drain-session, written by record-session, which
#     bin/fm-session-start.sh runs once per locked session start: the session
#     lock's anchor pid, whether that harness is Claude, and the store this
#     session runs on ($CLAUDE_CONFIG_DIR in the harness's own environment).
#     A record whose pid is not the current live lock holder is an older
#     session's and is ignored.
#   - the drain file the config names (the quota watch's drain.json). It is a
#     second input only: an absent, unreadable or stale one (t older than 30
#     minutes) changes nothing.
#
# check (state/account-drain.check.sh, armed once with `arm`; the watcher runs
# it on its check cadence) prints one line, "account-moved: ...", the first
# time it sees that the launch line names a different account than this
# session runs on. It stays silent while an away or quiet record exists
# (state/.afk-contract or state/.afk: neither mode's contract allows a helm to
# end itself, so the wake waits for the mode to end), while a fresh drain file
# names a different launch_line_account (the switch is still moving), and
# after it has announced that move for this session (state/.account-drain-
# announced). check also keeps the capability marker current.
#
# handover runs inside the helm, after /stow, at an idle moment. It refuses,
# leaving the helm running and saying why, when: the home is not configured;
# this process is not inside the session-lock holder's harness; no move is
# pending; an away or quiet record exists; a spawn, teardown or merge holds a
# task lock (state/.task-set.lock, state/.spawn-*.lock, state/.control-*.lock);
# this move's handover is in progress or done (state/.account-drain-handover;
# one called off or failed may be retried); or no
# handover_command is configured (it then prints what to run by hand). An
# away, quiet or busy-lock refusal, or a waiter that stands down for one,
# clears the announcement, so the check raises the move again once it
# clears. Then it
# starts one detached waiter, which takes the task-set lock (role
# account-handover) so no spawn or forced teardown starts behind it, and sends
# the captain one line through notify_command naming the account to pick in
# the Claude app. A failed notify aborts the waiter and the helm keeps
# running. The waiter waits a grace period (FM_ACCOUNT_DRAIN_GRACE, default
# 30 seconds) so the helm can end its turn, rechecks the lock holder, the
# away or quiet record and the task locks, sends SIGTERM to the lock
# holder's anchor pid (a POSIX pid only), waits for it to exit (FM_ACCOUNT_DRAIN_EXIT_WAIT, default 60 seconds; it never escalates to
# SIGKILL), releases the task-set lock and runs handover_command, which owns
# the fresh start and its own failure report (the fleet's helm-autostart pages
# when no helm takes the lock). Workers keep running: the fresh helm's
# ordinary session-start recovery reads their records and endpoints. The
# waiter logs to state/account-drain-handover.log.
#
# both-low exits 0 only when both_low_spill names a spill profile and a fresh
# drain file says both_low true; it prints the reason with both reset times on
# line 1 and the spill flags on line 2. bin/fm-spawn.sh refuses a Claude ship
# or scout on that answer and names the spill flags; the dispatch reference
# routes those workers to the spill profile. Exit 1 means no information or not
# low, so a missing or stale file never holds dispatch.
#
# The capability marker (handover_marker) is a JSON file the quota watch reads:
# {"version":1,"home":"<FM_HOME>","capable":true|false,"t":<epoch>}. capable is
# true only when handover_command is executable and the recorded session is a
# Claude helm that holds the lock. record-session writes it, and check rewrites
# it when capable changes or it is a day old.
set -u
export LC_ALL=C

# --help answers before any library is sourced: fm-wake-lib.sh creates state/.
case "${1:-}" in
  -h | --help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG="$CONFIG_DIR/account-drain"
LAUNCH_LINE_FILE="$CONFIG_DIR/primary-harness"
SESSION_RECORD="$STATE/.account-drain-session"
ANNOUNCED_RECORD="$STATE/.account-drain-announced"
HANDOVER_RECORD="$STATE/.account-drain-handover"
HANDOVER_ABORT="$STATE/.account-drain-handover.abort"
HANDOVER_LOG="$STATE/account-drain-handover.log"
CHECK_ID=account-drain
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
DRAIN_FRESH_SECS=1800
MARKER_REFRESH_SECS=86400
GRACE=${FM_ACCOUNT_DRAIN_GRACE:-30}
EXIT_WAIT=${FM_ACCOUNT_DRAIN_EXIT_WAIT:-60}
ARM_WAIT=${FM_ACCOUNT_DRAIN_ARM_WAIT:-10}
NOTIFY_TIMEOUT=30
case "$GRACE" in '' | *[!0-9]*) GRACE=30 ;; esac
case "$EXIT_WAIT" in '' | *[!0-9]*) EXIT_WAIT=60 ;; esac
case "$ARM_WAIT" in '' | *[!0-9]*) ARM_WAIT=10 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

say() { printf 'fm-account-drain: %s\n' "$*"; }
refuse() { say "$*" >&2; exit 1; }

# --- config ---------------------------------------------------------------
# config_get <key>: the value of the last "key=value" line, trimmed.
config_get() {
  [ -f "$CONFIG" ] || return 1
  awk -v k="$1" '
    /^[[:space:]]*#/ || !/=/ { next }
    { key = $0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != k) next
      val = $0; sub(/^[^=]*=/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      found = 1; out = val }
    END { if (found) print out; else exit 1 }' "$CONFIG"
}

configured() { [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ]; }

expand_path() {  # <path>: a leading ~/ becomes $HOME/; a trailing / is dropped
  local p=$1
  # shellcheck disable=SC2088 # a literal ~/ prefix is what this expands
  case "$p" in
    '~') p=$HOME ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
  esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  printf '%s\n' "$p"
}

# normalize_store <value>: "" and "ordinary" are the ordinary store; anything
# else is an expanded path.
normalize_store() {
  case "${1:-}" in
    '' | ordinary) printf 'ordinary\n' ;;
    *) expand_path "$1" ;;
  esac
}

# account_name <store>: the config's account.<name> whose store list holds
# <store>, else <store> itself.
account_name() {
  local store=$1 line key name word
  local -a words
  if configured; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
      key=${line%%=*}
      [ "$key" != "$line" ] || continue
      key=$(printf '%s' "$key" | tr -d '[:space:]')
      case "$key" in account.?*) name=${key#account.} ;; *) continue ;; esac
      read -r -a words <<<"${line#*=}"
      for word in ${words[@]+"${words[@]}"}; do
        if [ "$(normalize_store "$word")" = "$store" ]; then
          printf '%s\n' "$name"
          return 0
        fi
      done
    done < "$CONFIG"
  fi
  printf '%s\n' "$store"
}

account_label() {  # <name>: label.<name>, else the name
  local label
  label=$(config_get "label.$1" 2>/dev/null) && [ -n "$label" ] || label=$1
  printf '%s\n' "$label"
}

# command_words <key>: loads the configured command into CMD_WORDS; fails when
# unset, empty, or its first word does not resolve to an executable.
CMD_WORDS=()
command_words() {
  local value
  CMD_WORDS=()
  value=$(config_get "$1" 2>/dev/null) || return 1
  read -r -a CMD_WORDS <<<"$value"
  [ "${#CMD_WORDS[@]}" -gt 0 ] || return 1
  CMD_WORDS[0]=$(expand_path "${CMD_WORDS[0]}")
  command -v -- "${CMD_WORDS[0]}" >/dev/null 2>&1
}

# --- launch line ------------------------------------------------------------
# Sets LINE_HARNESS and LINE_STORE from config/primary-harness, the way
# bin/firstmate reads it. Fails when the file has no meaningful line.
LINE_HARNESS='' LINE_STORE=''
read_launch_line() {
  local line word store=''
  local -a words
  LINE_HARNESS='' LINE_STORE=''
  [ -f "$LAUNCH_LINE_FILE" ] || return 1
  line=$(grep -v '^[[:space:]]*#' "$LAUNCH_LINE_FILE" 2>/dev/null | grep -m1 '[^[:space:]]') || return 1
  read -r -a words <<<"$line"
  for word in "${words[@]}"; do
    if [[ "$word" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      case "$word" in CLAUDE_CONFIG_DIR=*) store=${word#CLAUDE_CONFIG_DIR=} ;; esac
      continue
    fi
    LINE_HARNESS=$(basename -- "$word")
    break
  done
  [ -n "$LINE_HARNESS" ] || return 1
  LINE_STORE=$(normalize_store "$store")
}

# --- session record ---------------------------------------------------------
record_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# live_lock_pid: the current session lock's pid when a live harness holds it.
live_lock_pid() {
  fm_session_lock_inspect "$STATE"
  [ "$FM_LOCK_INSPECT_STATE" = held ] || return 1
  printf '%s\n' "$FM_LOCK_INSPECT_PID"
}

# Sets SESSION_PID, SESSION_HARNESS and SESSION_STORE from a record that names
# the current live lock holder; fails otherwise.
SESSION_PID='' SESSION_HARNESS='' SESSION_STORE=''
read_session() {
  local pid
  SESSION_PID='' SESSION_HARNESS='' SESSION_STORE=''
  [ -f "$SESSION_RECORD" ] && [ ! -L "$SESSION_RECORD" ] || return 1
  [ "$(head -n 1 "$SESSION_RECORD" 2>/dev/null)" = fm-account-drain-session-v1 ] || return 1
  pid=$(live_lock_pid) || return 1
  [ "$(record_field "$SESSION_RECORD" pid)" = "$pid" ] || return 1
  SESSION_PID=$pid
  SESSION_HARNESS=$(record_field "$SESSION_RECORD" harness)
  SESSION_STORE=$(record_field "$SESSION_RECORD" store)
  [ -n "$SESSION_STORE" ]
}

write_private() {  # <file> <content>: atomic, 0600, symlink-refusing
  local file=$1 content=$2 tmp
  [ ! -L "$file" ] || return 1
  tmp=$(umask 077; mktemp "$(dirname "$file")/.fm-account-drain.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- drain file ---------------------------------------------------------------
# drain_json: prints the drain file when it is valid, version 1 and fresh.
drain_json() {
  local path now
  path=$(config_get drain_file 2>/dev/null) && [ -n "$path" ] || return 1
  path=$(expand_path "$path")
  [ -f "$path" ] || return 1
  now=$(date +%s)
  jq -ce --argjson now "$now" --argjson fresh "$DRAIN_FRESH_SECS" '
    select(type == "object" and .version == 1 and (.t | type) == "number"
      and .t <= $now + 300 and $now - .t <= $fresh)' "$path" 2>/dev/null
}

# --- moves --------------------------------------------------------------------
# Sets FROM_NAME and TO_NAME and succeeds when the launch line names a
# different account than this session runs on. Needs read_session first.
FROM_NAME='' TO_NAME=''
move_pending() {
  FROM_NAME='' TO_NAME=''
  [ "$SESSION_HARNESS" = claude ] || return 1
  read_launch_line || return 1
  [ "$LINE_HARNESS" = claude ] || return 1
  FROM_NAME=$(account_name "$SESSION_STORE")
  TO_NAME=$(account_name "$LINE_STORE")
  [ "$FROM_NAME" != "$TO_NAME" ]
}

# drain_disagrees: a fresh drain file names another launch_line_account.
drain_disagrees() {
  local json named
  json=$(drain_json) || return 1
  named=$(jq -r '.launch_line_account // empty | strings' <<<"$json" 2>/dev/null)
  [ -n "$named" ] && [ "$named" != "$TO_NAME" ]
}

away_or_quiet() {
  [ -e "$STATE/.afk-contract" ] || [ -L "$STATE/.afk-contract" ] \
    || [ -e "$STATE/.afk" ] || [ -L "$STATE/.afk" ]
}

# lock_holder_live <lockdir>: the lock directory's recorded holder is alive.
lock_holder_live() {
  local lockdir=$1 owner pid
  owner=$lockdir
  if [ -L "$lockdir" ]; then
    owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null) || return 1
  fi
  [ -d "$owner" ] || return 1
  pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  fm_lock_holder_alive "$owner" "$pid"
}

# busy_task_locks [<skip>]: prints each task lock a live process holds.
busy_task_locks() {
  local skip=${1:-} lock
  for lock in "$STATE/.task-set.lock" "$STATE"/.spawn-*.lock "$STATE"/.control-*.lock; do
    [ -e "$lock" ] || [ -L "$lock" ] || continue
    [ "$lock" != "$skip" ] || continue
    lock_holder_live "$lock" && printf '%s\n' "${lock##*/}"
  done
  return 0
}

# --- capability marker ----------------------------------------------------------
marker_capable() {
  command_words handover_command || return 1
  read_session || return 1
  [ "$SESSION_HARNESS" = claude ]
}

# write_marker [refresh]: writes the marker; with refresh, only when capable
# changed or the marker is older than a day.
write_marker() {
  local path capable=false now old_capable old_t json
  path=$(config_get handover_marker 2>/dev/null) && [ -n "$path" ] || return 0
  path=$(expand_path "$path")
  ! marker_capable || capable=true
  now=$(date +%s)
  if [ "${1:-}" = refresh ] && [ -f "$path" ]; then
    old_capable=$(jq -r '.capable' "$path" 2>/dev/null || true)
    old_t=$(jq -r '.t // 0 | numbers' "$path" 2>/dev/null || echo 0)
    case "$old_t" in '' | *[!0-9]*) old_t=0 ;; esac
    if [ "$old_capable" = "$capable" ] && [ $((now - old_t)) -lt "$MARKER_REFRESH_SECS" ]; then
      return 0
    fi
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  json=$(jq -cn --arg home "$FM_HOME" --argjson capable "$capable" --argjson t "$now" \
    '{version: 1, home: $home, capable: $capable, t: $t}') || return 1
  write_private "$path" "$json"
}

# --- notify -------------------------------------------------------------------------
# notify <message>: 0 sent, 1 the configured command failed, 2 none configured.
notify() {  # <message>
  command_words notify_command || return 2
  fm_run_timed "$NOTIFY_TIMEOUT" "${CMD_WORDS[@]}" "$1" >/dev/null 2>&1 || return 1
}

# --- subcommands ----------------------------------------------------------------------
cmd_record_session() {
  local pid harness=other store
  configured || return 0
  [ -d "$STATE" ] || return 0
  fm_session_lock_owned_by_self "$STATE" || return 0
  pid=$(head -n 1 "$STATE/.lock" 2>/dev/null) || return 0
  fm_session_pid_valid "$pid" || return 0
  if fm_harness_process_matches "$(fm_ps_comm "$pid" 2>/dev/null)" "$(fm_ps_args "$pid" 2>/dev/null)" \
    && [ "$FM_HARNESS_IS_CLAUDE" = 1 ]; then
    harness=claude
  fi
  store=$(normalize_store "${CLAUDE_CONFIG_DIR:-}")
  write_private "$SESSION_RECORD" "fm-account-drain-session-v1
pid=$pid
harness=$harness
store=$store
t=$(date +%s)" || return 1
  write_marker
}

cmd_check() {
  local key
  configured || return 0
  write_marker refresh || true
  read_session || return 0
  away_or_quiet && return 0
  move_pending || return 0
  drain_disagrees && return 0
  key="$SESSION_PID $LINE_STORE"
  [ "$(cat "$ANNOUNCED_RECORD" 2>/dev/null)" != "$key" ] || return 0
  printf 'account-moved: this helm runs on %s and the launch line now names %s; at the next idle moment (no captain turn in progress, no open question) run /stow, then bin/fm-account-drain.sh handover\n' \
    "$FROM_NAME" "$TO_NAME"
  write_private "$ANNOUNCED_RECORD" "$key" || true
}

cmd_both_low() {
  local spill harness model effort json
  configured || return 1
  spill=$(config_get both_low_spill 2>/dev/null) || return 1
  read -r harness model effort _ <<<"$spill"
  case "$harness" in '' | off) return 1 ;; esac
  if [ -z "$model" ] || [ -z "$effort" ]; then
    say "config/account-drain both_low_spill must be off or '<harness> <model> <effort>'; treating it as off" >&2
    return 1
  fi
  json=$(drain_json) || return 1
  jq -e '.both_low == true' <<<"$json" >/dev/null 2>&1 || return 1
  jq -r --argjson now "$(date +%s)" '
    "both Claude accounts are at or under the floor (drain file \($now - .t)s old): "
    + ([(.resets | if type == "object" then to_entries[] else empty end) | select(.value | type == "number")
        | "\(.key) resets \(.value | floor | todate)"] | if length == 0 then "no reset times" else join(", ") end)' <<<"$json" \
    || return 1
  printf 'spill: --harness %s --model %s --effort %s\n' "$harness" "$model" "$effort"
}

cmd_handover() {
  local busy key waiter_pid deadline status msg from_label to_label manual
  configured || refuse "not configured: config/account-drain is absent, so this helm keeps running"
  fm_session_lock_owned_by_self "$STATE" \
    || refuse "this process is not inside the helm that holds the session lock; nothing changed"
  read_session || refuse "no session record names the current lock holder; nothing changed (bin/fm-session-start.sh records it)"
  case "$SESSION_PID" in
    '' | *[!0-9]*) refuse "the session lock names a non-POSIX pid ($SESSION_PID), which this handover cannot end; nothing changed" ;;
  esac
  move_pending || refuse "no account move is pending: this helm and the launch line name the same account"
  # An away/quiet or busy refusal clears the announcement, so the check raises
  # the move again once that condition clears.
  away_or_quiet && { rm -f -- "$ANNOUNCED_RECORD"; refuse "an away or quiet record exists (state/.afk-contract or state/.afk); the handover waits until that mode ends, and this helm keeps running"; }
  busy=$(busy_task_locks)
  if [ -n "$busy" ]; then
    rm -f -- "$ANNOUNCED_RECORD"
    refuse "a spawn, teardown or merge holds a task lock ($(printf '%s' "$busy" | tr '\n' ' ' | sed 's/ $//')); the check raises the move again"
  fi
  key="$SESSION_PID $LINE_STORE"
  # One handover per move: one in progress or done refuses; one that was
  # called off or failed before a fresh helm started may be retried.
  if [ -f "$HANDOVER_RECORD" ] && [ "$(head -n 1 "$HANDOVER_RECORD")" = "$key" ]; then
    case "$(record_field "$HANDOVER_RECORD" status)" in
      starting | armed | go | done)
        refuse "this move was already handed over ($(record_field "$HANDOVER_RECORD" status)); see state/account-drain-handover.log"
        ;;
    esac
  fi
  from_label=$(account_label "$FROM_NAME")
  to_label=$(account_label "$TO_NAME")
  manual="end this session and start firstmate again (on Heimdall: firstmate, or ssh -t heimdall firstmate from away)"
  if ! command_words handover_command; then
    say "the launch line moved this helm from $from_label to $to_label, but no executable handover_command is configured in config/account-drain, so this helm keeps running on $from_label; to move it by hand: $manual"
    exit 3
  fi

  rm -f -- "$HANDOVER_ABORT"
  write_private "$HANDOVER_RECORD" "$key
status=starting
t=$(date +%s)" || refuse "could not write $HANDOVER_RECORD; nothing changed"
  (
    set -m
    nohup env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
      FM_ACCOUNT_DRAIN_GRACE="$GRACE" FM_ACCOUNT_DRAIN_EXIT_WAIT="$EXIT_WAIT" \
      bash "${BASH_SOURCE[0]}" _waiter "$SESSION_PID" "$LINE_STORE" "$FROM_NAME" "$TO_NAME" \
      >>"$HANDOVER_LOG" 2>&1 </dev/null &
    printf '%s\n' "$!" > "$HANDOVER_RECORD.pid"
  )
  waiter_pid=$(cat "$HANDOVER_RECORD.pid" 2>/dev/null || true)
  rm -f -- "$HANDOVER_RECORD.pid"
  deadline=$((SECONDS + ARM_WAIT))
  status=
  while [ "$SECONDS" -le "$deadline" ]; do
    status=$(record_field "$HANDOVER_RECORD" status)
    [ "$status" = starting ] || break
    sleep 0.2
  done
  if [ "$status" != armed ]; then
    : > "$HANDOVER_ABORT"
    [ "$status" != starting ] || waiter_status "$key" "failed (the waiter did not arm)" || true
    refuse "the handover waiter did not arm (status: ${status:-none}; see state/account-drain-handover.log), so this helm keeps running on $from_label"
  fi

  msg="Firstmate helm: moving from $from_label to $to_label now. Pick $to_label in the Claude app to reach the new helm."
  notify "$msg"
  case $? in
    0) ;;
    2) say "no notify_command is configured; tell the captain in this turn's final message: $msg" ;;
    *)
      : > "$HANDOVER_ABORT"
      refuse "the notify_command failed, so the handover was called off and this helm keeps running on $from_label"
      ;;
  esac
  [ "$(record_field "$HANDOVER_RECORD" status)" = armed ] || {
    : > "$HANDOVER_ABORT"
    refuse "the handover waiter stood down before the go ($(record_field "$HANDOVER_RECORD" status)), so this helm keeps running on $from_label"
  }
  waiter_status "$key" go || {
    : > "$HANDOVER_ABORT"
    refuse "could not release the handover waiter, so this helm keeps running on $from_label"
  }
  say "handover armed (waiter pid ${waiter_pid:-unknown}): this session ends in about ${GRACE}s, then ${CMD_WORDS[*]} starts a fresh helm on $to_label once the session lock frees. End this turn now."
}

waiter_status() {  # <key> <status>
  write_private "$HANDOVER_RECORD" "$1
status=$2
t=$(date +%s)"
}

cmd_waiter() {
  local pid=$1 store=$2 from=$3 to=$4 key lock waited busy rc
  key="$pid $store"
  lock=$(fm_task_set_lock_path "$STATE") || { waiter_status "$key" failed; exit 1; }
  printf '%s waiter %s: taking %s\n' "$(date -u +%FT%TZ)" "$$" "${lock##*/}"
  if ! fm_task_set_lock_try_acquire "$lock" || ! fm_lock_set_role "$lock" account-handover; then
    fm_lock_release "$lock" 2>/dev/null || true
    printf '%s waiter: the task-set lock is held; handover not armed\n' "$(date -u +%FT%TZ)"
    waiter_status "$key" failed
    exit 1
  fi
  # shellcheck disable=SC2064 # the lock path is fixed for this process
  trap "fm_lock_release '$lock' 2>/dev/null || true" EXIT
  waiter_status "$key" armed
  # The helm says go once its notify line is sent; no go in time calls it off.
  waited=0
  while [ "$(record_field "$HANDOVER_RECORD" status)" != go ]; do
    if [ -e "$HANDOVER_ABORT" ] || [ "$waited" -ge $((NOTIFY_TIMEOUT + ARM_WAIT + 5)) ]; then
      rm -f -- "$HANDOVER_ABORT"
      printf '%s waiter: called off before go\n' "$(date -u +%FT%TZ)"
      waiter_status "$key" aborted
      exit 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  waited=0
  while [ "$waited" -lt "$GRACE" ]; do
    if [ -e "$HANDOVER_ABORT" ]; then
      rm -f -- "$HANDOVER_ABORT"
      printf '%s waiter: called off by the helm\n' "$(date -u +%FT%TZ)"
      waiter_status "$key" aborted
      exit 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  [ ! -e "$HANDOVER_ABORT" ] || { rm -f -- "$HANDOVER_ABORT"; waiter_status "$key" aborted; exit 0; }
  if [ "$(live_lock_pid 2>/dev/null || true)" != "$pid" ]; then
    printf '%s waiter: the session lock no longer names pid %s; nothing ended\n' "$(date -u +%FT%TZ)" "$pid"
    waiter_status "$key" failed
    notify "Firstmate helm: the move to $(account_label "$to") stopped because the helm changed before it could end; no helm was ended." || true
    exit 1
  fi
  if away_or_quiet; then
    printf '%s waiter: an away or quiet record appeared; nothing ended\n' "$(date -u +%FT%TZ)"
    waiter_status "$key" aborted
    rm -f -- "$ANNOUNCED_RECORD"
    notify "Firstmate helm: the move to $(account_label "$to") waits because away or quiet mode started; the helm keeps running on $(account_label "$from")." || true
    exit 0
  fi
  busy=$(busy_task_locks "$lock")
  if [ -n "$busy" ]; then
    printf '%s waiter: task locks are held (%s); nothing ended\n' "$(date -u +%FT%TZ)" "$(printf '%s' "$busy" | tr '\n' ' ')"
    waiter_status "$key" failed
    rm -f -- "$ANNOUNCED_RECORD"
    notify "Firstmate helm: the move to $(account_label "$to") stopped because a spawn, teardown or merge started; the helm keeps running on $(account_label "$from")." || true
    exit 1
  fi
  printf '%s waiter: ending helm pid %s with SIGTERM\n' "$(date -u +%FT%TZ)" "$pid"
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while fm_pid_alive "$pid" && [ "$waited" -lt "$EXIT_WAIT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if fm_pid_alive "$pid"; then
    printf '%s waiter: pid %s still runs after %ss; no fresh helm started\n' "$(date -u +%FT%TZ)" "$pid" "$EXIT_WAIT"
    waiter_status "$key" failed
    notify "Firstmate helm: the old helm did not end, so it keeps running on $(account_label "$from") and no fresh helm started." || true
    exit 1
  fi
  fm_lock_release "$lock" 2>/dev/null || true
  trap - EXIT
  if ! command_words handover_command; then
    printf '%s waiter: handover_command is no longer executable\n' "$(date -u +%FT%TZ)"
    waiter_status "$key" failed
    notify "Firstmate helm: the old helm ended but handover_command is not executable; start it by hand with firstmate." || true
    exit 1
  fi
  printf '%s waiter: running %s\n' "$(date -u +%FT%TZ)" "${CMD_WORDS[*]}"
  "${CMD_WORDS[@]}"
  rc=$?
  printf '%s waiter: %s exited %s\n' "$(date -u +%FT%TZ)" "${CMD_WORDS[0]}" "$rc"
  if [ "$rc" -eq 0 ]; then
    waiter_status "$key" 'done'
  else
    waiter_status "$key" "failed (start command exited $rc)"
  fi
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-account-drain.sh - helm account-move check shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-account-drain.sh") check"
}

cmd_arm() {
  local home device tmp want
  configured || refuse "not configured: config/account-drain is absent; nothing to arm"
  mkdir -p "$STATE" || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || refuse "cannot resolve FM_HOME $FM_HOME"
  want=$(shim_content "$home")
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || refuse "state directory is unavailable"
  device=$(fm_pr_file_device "$STATE") || refuse "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || refuse "cannot write $CHECK_SHIM"
  tmp=$(umask 077; mktemp "$STATE/.fm-account-drain-check.XXXXXX") || refuse "cannot write $CHECK_SHIM"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    refuse "cannot write $CHECK_SHIM"
  fi
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    refuse "could not register $CHECK_SHIM"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$ANNOUNCED_RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-}" in
  check) cmd_check ;;
  handover) cmd_handover ;;
  record-session) cmd_record_session ;;
  both-low) cmd_both_low ;;
  arm) cmd_arm ;;
  disarm) cmd_disarm ;;
  _waiter)
    [ "$#" -eq 5 ] || exit 2
    shift
    cmd_waiter "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
