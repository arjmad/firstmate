#!/usr/bin/env bash
# fm-helm-refresh.sh - clear a Claude primary to a fresh context after the stow
# guard's /stow pass came back reset-safe, instead of letting it compact.
#
# Usage:
#   fm-helm-refresh.sh request      the helm runs this, as its last step, only
#                                   when the /stow receipt that bin/fm-stow-guard.sh
#                                   asked for says the session is reset-safe
#   fm-helm-refresh.sh status       print the pending request and the newest log lines
#   fm-helm-refresh.sh run <token>  the detached owner `request` starts; not for hand use
#
# Why /clear and not a relaunch: Claude Code's /clear starts a new session in
# the same process, so the lock pid, the parked supervision host and its
# watcher, the Remote Control bridge session and the session name all stay as
# they are, while the context drops back to the fresh-start set (the system
# prompt, memory files and the SessionStart re-emit; no compaction summary and
# no re-injected skill bodies). bin/fm-lock.sh already re-keys a /clear under
# the same pid, and bin/fm-session-start.sh re-emits the digest for it.
# docs/verification/supervision.md "Helm refresh by /clear" holds the evidence.
#
# request refuses, exits 1 and changes nothing unless all of these hold:
#   - config/stow-guard holds restart=1 (docs/configuration.md "Stow guard");
#   - this process belongs to the session that holds state/.lock;
#   - state/.stow-guard.json holds an offer for exactly that session id (the
#     id in state/.lock-session), made within FM_HELM_REFRESH_OFFER_TTL seconds
#     (default 7200), so a /stow nobody asked for never restarts the helm;
#   - this process runs in a tmux or Herdr pane bin/fm-primary-pane-lib.sh
#     can prove;
#   - state/.afk and state/.afk-contract are absent;
#   - state/.helm-refresh.log records no typed /clear within FM_HELM_REFRESH_COOLDOWN
#     seconds (default 3600), so a fresh context that is already over the
#     guard's line is never cleared again and again;
#   - no other request is pending with a live owner.
# It then writes state/.helm-refresh-pending and starts `run` detached, in its
# own process group, so the owner outlives the tool call that started it and is
# never one of Claude's background tasks.
#
# run waits, up to FM_HELM_REFRESH_WAIT seconds (default 1800), for the turn to
# end: two proofs in a row, FM_HELM_REFRESH_POLL seconds apart (default 3),
# that the pane is idle with an empty composer (fm_primary_pane_idle_proven),
# with state/.question-open absent at each. It gives up, with no change, when
# the request is replaced or removed, the lock moves to another pid or process,
# the session id in state/.lock-session changes, away mode starts, restart=1
# leaves config/stow-guard, the pane leaves idle after a first proof (a new
# turn, a draft or a question the receipt does not cover), or the wait runs
# out. Then it types /clear through the backend's submit primitive, logs
# `typed`, waits up to FM_HELM_REFRESH_CLEAR_WAIT seconds (default 60) for
# state/.lock-session to name a new session under the same lock pid, and then,
# once the pane proves idle twice again (up to FM_HELM_REFRESH_KICK_WAIT, default 120),
# rings one record-backed watcher doorbell so the fresh session reads its
# digest and goes on supervising. Every outcome is one line in
# state/.helm-refresh.log. Any stop before /clear leaves the session exactly
# as it was, so Claude's own compaction stays the fallback.
#
# Exit status: request 0 requested (or already pending), 1 refused, 2 usage;
# status 0; run 0 cleared, 1 gave up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PENDING="$STATE/.helm-refresh-pending"
OWNER="$STATE/.helm-refresh-owner"
LOG="$STATE/.helm-refresh.log"
GUARD_STATE="$STATE/.stow-guard.json"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

posint() {  # <value> <default>
  case "${1:-}" in
    ''|0*|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

OFFER_TTL=$(posint "${FM_HELM_REFRESH_OFFER_TTL:-}" 7200)
WAIT=$(posint "${FM_HELM_REFRESH_WAIT:-}" 1800)
POLL=$(posint "${FM_HELM_REFRESH_POLL:-}" 3)
CLEAR_WAIT=$(posint "${FM_HELM_REFRESH_CLEAR_WAIT:-}" 60)
KICK_WAIT=$(posint "${FM_HELM_REFRESH_KICK_WAIT:-}" 120)
COOLDOWN=$(posint "${FM_HELM_REFRESH_COOLDOWN:-}" 3600)

log() {  # <event> <detail>
  local tmp
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG")" -gt 200 ]; then
    tmp=$(mktemp "$LOG.XXXXXX") || return 0
    tail -100 "$LOG" > "$tmp" && mv -f "$tmp" "$LOG"
  fi
}

refuse() {  # <reason>
  echo "fm-helm-refresh: not requested: $1. The session keeps its context, and compaction stays the fallback." >&2
  exit 1
}

opted_in() {
  grep -Eq '^restart=1[[:space:]]*$' "$CONFIG/stow-guard" 2>/dev/null
}

# Away posture starts with state/.afk-contract before state/.afk is written.
away_mode_on() {
  [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-contract" ]
}

pending_field() {  # <field>
  jq -r --arg f "$1" '.[$f] // empty' "$PENDING" 2>/dev/null
}

owner_alive() {
  local pid identity
  [ -f "$OWNER" ] || return 1
  IFS=$'\t' read -r pid identity < "$OWNER" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$pid" && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ]
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  request|status) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  run) [ "$#" -eq 2 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-helm-refresh: jq is required" >&2; exit 1; }
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-primary-pane-lib.sh
. "$SCRIPT_DIR/fm-primary-pane-lib.sh"

if [ "$1" = status ]; then
  if [ -f "$PENDING" ]; then
    printf 'pending: %s\n' "$(jq -c . "$PENDING" 2>/dev/null || echo unreadable)"
    if owner_alive; then echo "owner: running"; else echo "owner: not running"; fi
  else
    echo "pending: none"
  fi
  if [ -f "$LOG" ]; then
    echo "log:"
    tail -5 "$LOG"
  fi
  exit 0
fi

if [ "$1" = request ]; then
  opted_in || refuse "config/stow-guard does not hold restart=1"
  fm_session_lock_owned_by_self "$STATE" \
    || refuse "this process is not in the session that holds the firstmate session lock"
  lock_pid=$(head -n 1 "$STATE/.lock" 2>/dev/null)
  lock_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null) || lock_identity=
  [ -n "$lock_identity" ] || refuse "the session lock's process identity cannot be read"
  sid=$(cat "$STATE/.lock-session" 2>/dev/null) || sid=
  [ -n "$sid" ] || refuse "no trusted Claude session id is recorded beside the lock"
  offer_sid=$(jq -r '.offer.sid // empty' "$GUARD_STATE" 2>/dev/null) || offer_sid=
  offer_at=$(jq -r '.offer.at // empty' "$GUARD_STATE" 2>/dev/null) || offer_at=
  [ -n "$offer_sid" ] && [ "$offer_sid" = "$sid" ] \
    || refuse "the stow guard made no restart offer to this session"
  case "$offer_at" in ''|*[!0-9]*) refuse "the stow guard's restart offer has no readable time" ;; esac
  [ $(( $(date +%s) - offer_at )) -le "$OFFER_TTL" ] \
    || refuse "the stow guard's restart offer is older than ${OFFER_TTL}s"
  # The default Herdr session puts no HERDR_SESSION in its panes, and the
  # Heimdall helm runs there.
  fm_primary_pane_transport --default-session \
    || refuse "this session runs in no tmux or Herdr pane a restart can prove"
  ! away_mode_on || refuse "away mode is on"
  # Every /clear logs `typed` before its re-key wait, so a clear whose re-key
  # came late still counts.
  last_cleared=$(awk -F '\t' '$2 == "typed" || $2 == "cleared" { t = $1 } END { print t }' "$LOG" 2>/dev/null)
  case "$last_cleared" in ''|*[!0-9]*) last_cleared=0 ;; esac
  [ $(( $(date +%s) - last_cleared )) -ge "$COOLDOWN" ] \
    || refuse "this home cleared a session less than ${COOLDOWN}s ago, so a fresh context is already near the stow line"
  if [ -f "$PENDING" ] && owner_alive; then
    echo "fm-helm-refresh: already requested; the session clears once this turn ends."
    exit 0
  fi
  token="$(date +%s)-$$"
  tmp=$(mktemp "$PENDING.XXXXXX") || refuse "state/.helm-refresh-pending cannot be written"
  if ! jq -n --arg token "$token" --arg sid "$sid" --arg lock_pid "$lock_pid" \
    --arg lock_identity "$lock_identity" --arg transport "$FM_PRIMARY_PANE_TRANSPORT" \
    --arg target "$FM_PRIMARY_PANE_TARGET" --argjson at "$(date +%s)" \
    '{token:$token, sid:$sid, lock_pid:$lock_pid, lock_identity:$lock_identity,
      transport:$transport, target:$target, at:$at}' > "$tmp" \
    || ! mv -f "$tmp" "$PENDING"; then
    rm -f "$tmp"
    refuse "state/.helm-refresh-pending cannot be written"
  fi
  # Its own process group, stdio off the tool call, and no hangup: the owner
  # must outlive this command and must not be one of Claude's background tasks.
  set -m
  FM_HOME="$FM_HOME" nohup "$SCRIPT_DIR/fm-helm-refresh.sh" run "$token" \
    </dev/null >/dev/null 2>&1 &
  owner_pid=$!
  set +m
  log requested "token=$token sid=$sid transport=$FM_PRIMARY_PANE_TRANSPORT owner=$owner_pid"
  echo "fm-helm-refresh: requested; end the turn now. Once the pane is idle the session clears to a fresh context, and a doorbell starts its first turn."
  exit 0
fi

# --- run --------------------------------------------------------------------

TOKEN=$2

# Every end of this owner is one log line, and it removes only its own records.
finish() {  # <status> <event> <detail>
  log "$2" "token=$TOKEN $3"
  [ "$(pending_field token)" != "$TOKEN" ] || rm -f "$PENDING"
  [ "$(cut -f1 "$OWNER" 2>/dev/null)" != "$$" ] || rm -f "$OWNER"
  exit "$1"
}
trap 'finish 1 gave-up "stopped by a signal before it finished"' TERM INT HUP

[ "$(pending_field token)" = "$TOKEN" ] || finish 1 gave-up "the request was replaced or removed before the owner started"
SID=$(pending_field sid)
LOCK_PID=$(pending_field lock_pid)
LOCK_IDENTITY=$(pending_field lock_identity)
TRANSPORT=$(pending_field transport)
TARGET=$(pending_field target)
if [ -z "$SID" ] || [ -z "$LOCK_PID" ] || [ -z "$LOCK_IDENTITY" ] || [ -z "$TARGET" ]; then
  finish 1 gave-up "the pending request is incomplete"
fi
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
fm_backend_source tmux || finish 1 gave-up "the tmux adapter would not load"
case "$TRANSPORT" in
  tmux) ;;
  herdr) fm_backend_source herdr || finish 1 gave-up "the herdr adapter would not load" ;;
  *) finish 1 gave-up "unknown transport '$TRANSPORT'" ;;
esac

identity=$(fm_pid_identity "$$") || identity=
[ -n "$identity" ] || finish 1 gave-up "the owner's own process identity cannot be read"
tmp=$(mktemp "$OWNER.XXXXXX") || finish 1 gave-up "state/.helm-refresh-owner cannot be written"
if ! printf '%s\t%s\n' "$$" "$identity" > "$tmp" || ! mv -f "$tmp" "$OWNER"; then
  rm -f "$tmp"
  finish 1 gave-up "state/.helm-refresh-owner cannot be written"
fi

lock_held() {
  [ "$(head -n 1 "$STATE/.lock" 2>/dev/null)" = "$LOCK_PID" ] \
    && fm_pid_alive "$LOCK_PID" \
    && [ "$(fm_pid_identity "$LOCK_PID" 2>/dev/null)" = "$LOCK_IDENTITY" ]
}

# A reason to stop before /clear, or nothing when the request still stands.
stop_reason() {
  [ "$(pending_field token)" = "$TOKEN" ] || { echo "the request was replaced or removed"; return; }
  lock_held || { echo "the session lock moved to another process"; return; }
  [ "$(cat "$STATE/.lock-session" 2>/dev/null)" = "$SID" ] \
    || { echo "the session changed before the clear"; return; }
  ! away_mode_on || { echo "away mode turned on"; return; }
  opted_in || { echo "config/stow-guard no longer holds restart=1"; return; }
}

pane_ready() {
  [ ! -e "$STATE/.question-open" ] \
    && fm_primary_pane_idle_proven "$TRANSPORT" "$TARGET" "$LOCK_PID"
}

deadline=$((SECONDS + WAIT))
proofs=0
while :; do
  why=$(stop_reason)
  [ -z "$why" ] || finish 1 gave-up "$why; nothing was typed"
  [ "$SECONDS" -lt "$deadline" ] || finish 1 gave-up "the turn did not end within ${WAIT}s; nothing was typed"
  if pane_ready; then
    proofs=$((proofs + 1))
    [ "$proofs" -lt 2 ] || break
  elif [ "$proofs" -gt 0 ]; then
    # The stow's turn had ended. A busy pane, a draft or a question now means
    # new work the reset-safe receipt does not cover.
    finish 1 gave-up "the pane left idle after the stow's turn ended; nothing was typed"
  fi
  sleep "$POLL"
done

# One last check at the moment of typing, so a draft or question that arrived
# after the second proof, or a deadline it crossed, still types nothing.
why=$(stop_reason)
[ -z "$why" ] || finish 1 gave-up "$why; nothing was typed"
pane_ready || finish 1 gave-up "the pane stopped reading idle and empty just before /clear; nothing was typed"
[ "$SECONDS" -lt "$deadline" ] || finish 1 gave-up "the turn did not end within ${WAIT}s; nothing was typed"
verdict=$(fm_backend_send_text_submit "$TRANSPORT" "$TARGET" "/clear" 2 0.2 0.2 2>/dev/null) || verdict=unconfirmed
log typed "token=$TOKEN sid=$SID submit=$verdict"

# The re-key below is the proof that /clear ran, so an ambiguous submit
# verdict still waits for it rather than giving up on a session that cleared.
new_sid=
clear_deadline=$((SECONDS + CLEAR_WAIT))
while [ "$SECONDS" -lt "$clear_deadline" ]; do
  new_sid=$(cat "$STATE/.lock-session" 2>/dev/null) || new_sid=
  if [ -n "$new_sid" ] && [ "$new_sid" != "$SID" ] && lock_held; then
    break
  fi
  new_sid=
  sleep 1
done
[ -n "$new_sid" ] || finish 1 failed "/clear submit read '$verdict', and no new session took the lock within ${CLEAR_WAIT}s; look at the pane"
log cleared "token=$TOKEN sid=$SID new_sid=$new_sid lock_pid=$LOCK_PID submit=$verdict"

kick_deadline=$((SECONDS + KICK_WAIT))
kicked=deferred
proofs=0
while [ "$SECONDS" -lt "$kick_deadline" ]; do
  lock_held || break
  [ "$(cat "$STATE/.lock-session" 2>/dev/null)" = "$new_sid" ] || break
  if pane_ready; then
    proofs=$((proofs + 1))
  else
    proofs=0
  fi
  # Two proofs apart, as before the clear: the lock re-keys at the start of
  # the SessionStart hook, before the digest is in the new context.
  if [ "$proofs" -ge 2 ]; then
    if fm_operational_record_write "$STATE" watcher \
      'check: helm-refresh - this session was cleared to a fresh context after a reset-safe /stow, in place of compaction. Read the startup digest, run bin/fm-wake-drain.sh and handle its queued work, then go on supervising. This is automatic supervision, not a captain return.' message; then
      kicked=$(fm_backend_send_text_submit "$TRANSPORT" "$TARGET" "$message" 2 0.2 0.2 2>/dev/null) || kicked=unconfirmed
    fi
    break
  fi
  sleep "$POLL"
done
# The session cleared either way; a doorbell that did not read empty is
# reported as unconfirmed.
[ "$kicked" = empty ] || finish 1 failed "new_sid=$new_sid doorbell=$kicked; the session cleared, but its doorbell was not confirmed"
finish 0 finished "new_sid=$new_sid doorbell=$kicked"
