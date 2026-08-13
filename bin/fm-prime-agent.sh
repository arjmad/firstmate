#!/usr/bin/env bash
# Task-scoped Prime Agent v0.7.1 control adapter.
#
# Usage:
#   fm-prime-agent.sh resolve-bin
#   fm-prime-agent.sh launch <tmpdir> <session-dir> [prime-agent args...]
#   fm-prime-agent.sh discover <tmpdir> <session-dir> <cwd>
#   fm-prime-agent.sh state <task-meta>
#   fm-prime-agent.sh send <task-meta> <message>
#   fm-prime-agent.sh shutdown <tmpdir> <session-dir>
#   fm-prime-agent.sh cleanup <task-meta>
#
# Every command runs with the task's short TMPDIR, task-only session directory,
# telemetry opt-outs, and PRIME_AGENT_FIRSTMATE=1 detection marker. The captain's
# normal ~/.prime/agent settings and authentication remain the config source:
# this adapter never sets PRIME_AGENT_CODING_AGENT_DIR, reads auth files, or copies
# their contents. The installed pilot wrapper forces one shared TMPDIR, so the
# verified npm-prefix package binary is preferred in order to preserve task socket
# isolation. PRIME_AGENT_REAL_BIN is a test/operator override for another direct
# executable.
#
# state is authoritative for Prime Agent: it reads list --json and prints exactly
# busy, idle, missing, or unknown. Pane signatures are only a fast busy fallback
# elsewhere; absence of a spinner never proves Prime Agent is idle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-prime-tmp-lib.sh
. "$SCRIPT_DIR/fm-prime-tmp-lib.sh"

meta_get() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

resolve_bin() {
  local candidate
  if [ -n "${PRIME_AGENT_REAL_BIN:-}" ]; then
    candidate=$PRIME_AGENT_REAL_BIN
  elif [ -x "${HOME:-}/.local/prime-agent/node_modules/.bin/prime-agent" ]; then
    candidate="$HOME/.local/prime-agent/node_modules/.bin/prime-agent"
  else
    candidate=$(command -v prime-agent 2>/dev/null || true)
  fi
  [ -n "$candidate" ] && [ -x "$candidate" ] || {
    echo "error: direct prime-agent executable not found; set PRIME_AGENT_REAL_BIN or install the npm-prefix package under ~/.local/prime-agent" >&2
    return 1
  }
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      candidate=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate")
      [ -x "$candidate" ] || return 1
      printf '%s\n' "$candidate"
      ;;
  esac
}

safe_runtime_paths() {  # <tmpdir> <session-dir>
  fm_prime_tmp_path_safe "$1" || {
    echo "error: unsafe Prime Agent task TMPDIR: $1" >&2
    return 1
  }
  case "$2" in
    /*/state/prime-agent/*/sessions) ;;
    *) echo "error: unsafe Prime Agent task session directory: $2" >&2; return 1 ;;
  esac
}

valid_runtime_paths() {  # <tmpdir> <session-dir>
  safe_runtime_paths "$1" "$2" || return 1
  [ -d "$1" ] || { echo "error: Prime Agent task TMPDIR is missing: $1" >&2; return 1; }
  [ -d "$2" ] || { echo "error: Prime Agent task session directory is missing: $2" >&2; return 1; }
}

scoped_env() {  # <tmpdir> <session-dir>; sets SCOPED_ENV, the one task env block
  SCOPED_ENV=(env
    TMPDIR="$1"
    PRIME_AGENT_SESSION_DIR="$2"
    PRIME_AGENT_TELEMETRY=0
    DO_NOT_TRACK=1
    PRIME_AGENT_FIRSTMATE=1)
}

run_scoped() {  # <tmpdir> <session-dir> <args...>
  local tmp=$1 sessions=$2 bin
  shift 2
  valid_runtime_paths "$tmp" "$sessions" || return 1
  bin=$(resolve_bin) || return 1
  scoped_env "$tmp" "$sessions"
  "${SCOPED_ENV[@]}" "$bin" "$@"
}

daemon_socket() {  # <tmpdir>
  printf '%s/prime-agent-%s/daemon.sock' "$1" "$(id -u)"
}

daemon_alive() {  # <tmpdir>; true when a live process still holds the task daemon socket
  local sock
  sock=$(daemon_socket "$1")
  [ -e "$sock" ] || return 1
  # Without lsof the leftover socket cannot be proven dead, so treat it as live.
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -t -- "$sock" >/dev/null 2>&1
}

meta_runtime_shape() {  # <meta>; sets META_TMP META_SESS META_AGENT; ownership only, no existence
  local meta=$1 id state
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "error: unsafe or missing Prime Agent task metadata: $meta" >&2; return 1; }
  [ "$(meta_get "$meta" harness)" = prime-agent ] || { echo "error: metadata is not a Prime Agent task: $meta" >&2; return 1; }
  id=$(basename "$meta" .meta)
  state=$(cd "$(dirname "$meta")" 2>/dev/null && pwd -P) || return 1
  META_TMP=$(meta_get "$meta" prime_tmp)
  META_SESS=$(meta_get "$meta" prime_session_dir)
  META_AGENT=$(meta_get "$meta" prime_session)
  if [ -n "$META_SESS" ] && [ "$META_SESS" != "$state/prime-agent/$id/sessions" ]; then
    echo "error: Prime Agent session directory does not match task metadata owner" >&2
    return 1
  fi
  case "$META_AGENT" in
    *[!A-Za-z0-9_-]*) echo "error: invalid Prime Agent session id in $meta" >&2; return 1 ;;
  esac
}

meta_runtime() {  # <meta>; sets META_TMP META_SESS META_AGENT; requires a live runtime
  meta_runtime_shape "$1" || return 1
  valid_runtime_paths "$META_TMP" "$META_SESS" || return 1
  [ -n "$META_AGENT" ] || { echo "error: invalid or missing Prime Agent session id in $1" >&2; return 1; }
}

list_json() {  # <tmpdir> <session-dir>
  run_scoped "$1" "$2" list --json 2>/dev/null
}

discover() {  # <tmpdir> <session-dir> <cwd>
  local tmp=$1 sessions=$2 cwd=$3 json real
  [ -d "$cwd" ] || return 1
  real=$(cd "$cwd" && pwd -P) || return 1
  json=$(list_json "$tmp" "$sessions") || return 1
  printf '%s' "$json" | jq -er --arg cwd "$real" '
    [.sessions[]? | select(.lifecycle == "live" and .cwd == $cwd)]
    | if length == 1 then .[0].activeSessionId else empty end
  '
}

state_from_meta() {  # <meta>
  local json row
  meta_runtime "$1" || { printf 'unknown\n'; return 0; }
  json=$(list_json "$META_TMP" "$META_SESS") || { printf 'unknown\n'; return 0; }
  row=$(printf '%s' "$json" | jq -cer --arg id "$META_AGENT" '
    [.sessions[]? | select(.activeSessionId == $id or .id == $id)]
    | if length == 0 then "missing"
      elif length != 1 then "unknown"
      else .[0]
      | if type == "string" then .
        elif (.activity != "idle"
              or .isStreaming == true
              or .isRunningTools == true
              or .isBashRunning == true
              or .isCompacting == true
              or .hasRunningRlmChildren == true
              or ((.unfinishedActionCount // 0) > 0)) then "busy"
        elif (.activity == "idle"
              and .isStreaming == false
              and .isRunningTools == false
              and .isBashRunning == false
              and ((.unfinishedActionCount // 0) == 0)) then "idle"
        else "unknown" end
      end
  ' 2>/dev/null) || row=unknown
  case "$row" in busy|idle|missing|unknown) printf '%s\n' "$row" ;; *) printf 'unknown\n' ;; esac
}

send_from_meta() {  # <meta> <message>
  local json status mode
  meta_runtime "$1" || return 1
  json=$(run_scoped "$META_TMP" "$META_SESS" send "$META_AGENT" "$2" --json) || return 1
  status=$(printf '%s' "$json" | jq -r '.deliveryStatus // empty' 2>/dev/null) || return 1
  mode=$(printf '%s' "$json" | jq -r '.deliveryMode // empty' 2>/dev/null) || return 1
  case "$status:$mode" in
    queued:steer|delivered:steer) return 0 ;;
    *) echo "error: Prime Agent did not confirm steering delivery (status=${status:-unknown}, mode=${mode:-unknown})" >&2; return 1 ;;
  esac
}

shutdown_scoped() {  # <tmpdir> <session-dir>
  local tmp=$1 sessions=$2
  run_scoped "$tmp" "$sessions" shutdown --force --json >/dev/null 2>&1 || {
    # A daemon that already exited is an idempotent cleanup success, including
    # a killed daemon's leftover socket file; only a live holder is a failure.
    ! daemon_alive "$tmp" || return 1
  }
}

cleanup_from_meta() {  # <meta>
  local meta=$1
  meta_runtime_shape "$meta" || return 1
  # An already-removed task runtime is an idempotent cleanup success; unsafe or
  # another task's paths still fail closed.
  [ -n "$META_TMP" ] || [ -n "$META_SESS" ] || return 0
  safe_runtime_paths "$META_TMP" "$META_SESS" || return 1
  # Missing recorded directories or a missing executable prove nothing about
  # the daemon itself (the running node process needs neither), so success in
  # either case additionally requires that no live daemon holds the socket.
  if [ ! -d "$META_TMP" ] || [ ! -d "$META_SESS" ]; then
    ! daemon_alive "$META_TMP" || {
      echo "error: Prime Agent task runtime records are gone but a live daemon still holds $(daemon_socket "$META_TMP")" >&2
      return 1
    }
    return 0
  fi
  resolve_bin >/dev/null 2>&1 || {
    ! daemon_alive "$META_TMP" || {
      echo "error: direct prime-agent executable unavailable while a live daemon still holds $(daemon_socket "$META_TMP")" >&2
      return 1
    }
    echo "warning: direct prime-agent executable unavailable; skipping stop/shutdown for the ended task runtime" >&2
    return 0
  }
  # Plain stop is scoped to the recorded task session. The following daemon-wide
  # shutdown is safe only because every task has a unique TMPDIR/daemon socket.
  if [ -n "$META_AGENT" ]; then
    run_scoped "$META_TMP" "$META_SESS" stop "$META_AGENT" --json >/dev/null 2>&1 || true
  fi
  shutdown_scoped "$META_TMP" "$META_SESS"
}

case "${1:-}" in
  resolve-bin) resolve_bin ;;
  launch)
    [ "$#" -ge 3 ] || { echo "usage: fm-prime-agent.sh launch <tmpdir> <session-dir> [args...]" >&2; exit 2; }
    tmp=$2; sessions=$3; shift 3
    valid_runtime_paths "$tmp" "$sessions" || exit 1
    bin=$(resolve_bin) || exit 1
    scoped_env "$tmp" "$sessions"
    exec "${SCOPED_ENV[@]}" "$bin" "$@"
    ;;
  discover)
    [ "$#" = 4 ] || { echo "usage: fm-prime-agent.sh discover <tmpdir> <session-dir> <cwd>" >&2; exit 2; }
    discover "$2" "$3" "$4"
    ;;
  state)
    [ "$#" = 2 ] || { echo "usage: fm-prime-agent.sh state <task-meta>" >&2; exit 2; }
    state_from_meta "$2"
    ;;
  send)
    [ "$#" = 3 ] || { echo "usage: fm-prime-agent.sh send <task-meta> <message>" >&2; exit 2; }
    send_from_meta "$2" "$3"
    ;;
  shutdown)
    [ "$#" = 3 ] || { echo "usage: fm-prime-agent.sh shutdown <tmpdir> <session-dir>" >&2; exit 2; }
    shutdown_scoped "$2" "$3"
    ;;
  cleanup)
    [ "$#" = 2 ] || { echo "usage: fm-prime-agent.sh cleanup <task-meta>" >&2; exit 2; }
    cleanup_from_meta "$2"
    ;;
  *)
    echo "usage: fm-prime-agent.sh <resolve-bin|launch|discover|state|send|shutdown|cleanup> ..." >&2
    exit 2
    ;;
esac
