#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# Claude restart lanes additionally use state/.claude-primary-session, exactly:
#   session_id=VALIDATED_HOOK_PAYLOAD_SESSION_ID
#   lock_pid=NUMERIC_STATE_LOCK_OWNER_FOR_THIS_BINDING_GENERATION
# A pre-lock SessionStart proposal uses state/.claude-primary-session.pending:
#   session_id=VALIDATED_HOOK_PAYLOAD_SESSION_ID
#   harness_pid=RESOLVED_CLAUDE_HARNESS_PID
#   created_at=UNIX_SECONDS
# The successful matching fm-lock.sh owner promotes and removes that proposal.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|prime-agent|^pi$'

# True if $1 is in the current process ancestry. Claude's tool and Stop-hook
# execution lanes can have different nearer Claude-shaped processes, so exact
# nearest-ancestor equality is not a stable session identity by itself.
fm_pid_is_current_ancestor() {
  local target=$1 pid=$$ parent
  case "$target" in
    ''|*[!0-9]*) return 1 ;;
  esac
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$pid" = "$target" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    case "$parent" in
      ''|*[!0-9]*|0|1) return 1 ;;
    esac
    pid=$parent
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
}

fm_harness_pid_is_claude() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm")" | grep -Eq '^claude([._-].*)?$' && return 0
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -Eq '(^|[[:space:]/])claude([^[:space:]/]*)([[:space:]/]|$)'
      ;;
    *) return 1 ;;
  esac
}

# Print Claude's declared stable CLAUDE_PID when it is a live Claude process
# in the current ancestry; fail when it is unset, dead, not Claude-shaped, or
# not an ancestor. Success means this lane declares its own validated Claude
# session identity.
fm_claude_declared_ancestor_pid() {
  fm_pid_is_current_ancestor "${CLAUDE_PID:-}" || return 1
  fm_harness_pid_alive "$CLAUDE_PID" || return 1
  fm_harness_pid_is_claude "$CLAUDE_PID" || return 1
  printf '%s\n' "$CLAUDE_PID"
}

fm_claude_session_id_valid() {
  local session_id=$1
  [ -n "$session_id" ] && [ "${#session_id}" -le 128 ] || return 1
  case "$session_id" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
}

FM_CLAUDE_BOUND_SESSION_ID=
FM_CLAUDE_BOUND_LOCK_PID=
fm_claude_session_binding_load() {
  local state=$1 binding session_id lock_pid
  FM_CLAUDE_BOUND_SESSION_ID=
  FM_CLAUDE_BOUND_LOCK_PID=
  binding="$state/.claude-primary-session"
  [ -f "$binding" ] && [ ! -L "$binding" ] || return 1
  session_id=$(sed -n '1s/^session_id=//p' "$binding" 2>/dev/null || true)
  lock_pid=$(sed -n '2s/^lock_pid=//p' "$binding" 2>/dev/null || true)
  fm_claude_session_id_valid "$session_id" || return 1
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FM_CLAUDE_BOUND_SESSION_ID=$session_id
  FM_CLAUDE_BOUND_LOCK_PID=$lock_pid
}

# Publish the Claude payload session id only after the caller has independently
# verified ownership of the numeric home lock. The lock pid binds a carried
# record to one lock generation, so a stale record cannot authorize a later
# owner that reused the same home.
fm_claude_session_binding_write() {
  local state=$1 session_id=$2 binding lock_pid tmp back_session back_lock
  fm_claude_session_id_valid "$session_id" || return 1
  binding="$state/.claude-primary-session"
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  tmp=$(mktemp "$state/.claude-primary-session.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'session_id=%s\nlock_pid=%s\n' "$session_id" "$lock_pid" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$binding" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  [ -f "$binding" ] && [ ! -L "$binding" ] || return 1
  back_session=$(sed -n '1s/^session_id=//p' "$binding" 2>/dev/null || true)
  back_lock=$(sed -n '2s/^lock_pid=//p' "$binding" 2>/dev/null || true)
  [ "$back_session" = "$session_id" ] && [ "$back_lock" = "$lock_pid" ]
}

FM_CLAUDE_PENDING_SESSION_ID=
FM_CLAUDE_PENDING_HARNESS_PID=
FM_CLAUDE_PENDING_CREATED_AT=
fm_claude_session_pending_load() {
  local state=$1 pending session_id harness_pid created_at
  FM_CLAUDE_PENDING_SESSION_ID=
  FM_CLAUDE_PENDING_HARNESS_PID=
  FM_CLAUDE_PENDING_CREATED_AT=
  pending="$state/.claude-primary-session.pending"
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  session_id=$(sed -n '1s/^session_id=//p' "$pending" 2>/dev/null || true)
  harness_pid=$(sed -n '2s/^harness_pid=//p' "$pending" 2>/dev/null || true)
  created_at=$(sed -n '3s/^created_at=//p' "$pending" 2>/dev/null || true)
  fm_claude_session_id_valid "$session_id" || return 1
  case "$harness_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$created_at" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FM_CLAUDE_PENDING_SESSION_ID=$session_id
  FM_CLAUDE_PENDING_HARNESS_PID=$harness_pid
  FM_CLAUDE_PENDING_CREATED_AT=$created_at
}

# SessionStart runs before the model can acquire the home lock. Its proposal is
# inert data tied to that hook's resolved Claude harness pid; only a later
# successful lock owner with the same resolved pid can promote it.
fm_claude_session_pending_write() {
  local state=$1 session_id=$2 harness_pid pending tmp
  fm_claude_session_id_valid "$session_id" || return 1
  harness_pid=$(fm_harness_ancestry_pid) || return 1
  fm_harness_pid_is_claude "$harness_pid" || return 1
  pending="$state/.claude-primary-session.pending"
  tmp=$(mktemp "$state/.claude-primary-session.pending.tmp.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'session_id=%s\nharness_pid=%s\ncreated_at=%s\n' \
      "$session_id" "$harness_pid" "$(date +%s)" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$pending" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  fm_claude_session_pending_load "$state" \
    && [ "$FM_CLAUDE_PENDING_SESSION_ID" = "$session_id" ] \
    && [ "$FM_CLAUDE_PENDING_HARNESS_PID" = "$harness_pid" ]
}

fm_claude_session_pending_promote() {
  local state=$1 lock_pid my_pid now age
  fm_claude_session_pending_load "$state" || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ] \
    && [ "$FM_CLAUDE_PENDING_HARNESS_PID" = "$my_pid" ] \
    && fm_harness_pid_is_claude "$my_pid" \
    && fm_harness_pid_alive "$my_pid" \
    || return 1
  now=$(date +%s)
  age=$((now - FM_CLAUDE_PENDING_CREATED_AT))
  [ "$age" -ge 0 ] && [ "$age" -le 300 ] || return 1
  fm_claude_session_binding_write "$state" "$FM_CLAUDE_PENDING_SESSION_ID" || return 1
  rm -f "$state/.claude-primary-session.pending" 2>/dev/null || true
}

# Walk the current process ancestry (up to 8 hops) and print the nearest pid
# whose command looks like a verified harness. For Claude only, prefer its
# declared stable CLAUDE_PID when the nearer candidate is also Claude-shaped
# and the declared live Claude process is genuinely in this ancestry. This
# keeps tool and Stop-hook lanes in one Claude session on the same owner while
# preventing an inherited CLAUDE_PID from overriding a nested non-Claude
# harness or authorizing a competing session.
fm_harness_ancestry_pid() {
  local pid=$$ comm args candidate=
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      candidate=$pid
      break
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*)
        if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
          candidate=$pid
          break
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  [ -n "$candidate" ] || return 1

  local declared
  if fm_harness_pid_is_claude "$candidate" \
    && declared=$(fm_claude_declared_ancestor_pid); then
    echo "$declared"
  else
    echo "$candidate"
  fi
}

# True when state dir $1 holds a session lock owned by the current harness
# session. Optional $2 is the validated session id from a Claude hook payload.
# When a binding for the current lock generation exists, that id is
# authoritative even if a harness restart retained the outer lock owner while
# Stop moved to a distinct Claude process lane. This admits sibling Claude
# lanes from the rebound session without admitting a nested session, whose
# payload id differs. Without a current binding, exact resolved-owner equality
# remains the ordinary path and the legacy CLAUDE_PID-less ancestral fallback
# preserves restart compatibility during rollout.
fm_session_lock_owned_by_self() {
  local state=$1 session_id=${2:-} lock_pid my_pid session_bound=0
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -n "$session_id" ] \
    && { [ -e "$state/.claude-primary-session" ] || [ -L "$state/.claude-primary-session" ]; }; then
    fm_claude_session_binding_load "$state" || return 1
    if [ "$FM_CLAUDE_BOUND_LOCK_PID" = "$lock_pid" ]; then
      [ "$FM_CLAUDE_BOUND_SESSION_ID" = "$session_id" ] || return 1
      session_bound=1
    fi
  fi
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ] && return 0
  if [ "$session_bound" -eq 1 ]; then
    fm_harness_pid_is_claude "$my_pid" \
      && fm_harness_pid_is_claude "$lock_pid" \
      && fm_harness_pid_alive "$lock_pid"
    return
  fi
  fm_claude_declared_ancestor_pid >/dev/null && return 1
  fm_harness_pid_is_claude "$my_pid" \
    && fm_harness_pid_is_claude "$lock_pid" \
    && fm_harness_pid_alive "$lock_pid" \
    && fm_pid_is_current_ancestor "$lock_pid"
}
