#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
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
# session. Exact resolved-owner equality is the ordinary path. Restarted Claude
# sessions may dispatch Stop hooks through a nearer Claude daemon lane with no
# validated CLAUDE_PID of its own; only that shape may fall back to the
# recorded owner, and the owner must be a live Claude ancestor while the
# nearest resolved harness is also Claude. A lane that declares its own
# validated Claude identity distinct from the owner is a competing session and
# fails closed, as do missing, malformed, or unresolvable ownership and nested
# non-Claude harnesses.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ] && return 0
  fm_claude_declared_ancestor_pid >/dev/null && return 1
  fm_harness_pid_is_claude "$my_pid" \
    && fm_harness_pid_is_claude "$lock_pid" \
    && fm_harness_pid_alive "$lock_pid" \
    && fm_pid_is_current_ancestor "$lock_pid"
}
