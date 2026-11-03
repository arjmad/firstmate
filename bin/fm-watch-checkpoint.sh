#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# SUPERVISION HOST. A home opted in with config/supervision-host
# (docs/configuration.md "Supervision host" owns the gate;
# config/supervision-host-off opts out, and a Codex home without the file does not run the host) runs
# bin/fm-supervision-host.sh in the watcher's place for the checkpoint's bound,
# as the host's park boundary; the host takes away-posture wakes itself and
# returns only when main is needed (its header owns the output read here).
# While an away record state/.afk-contract exists (never quiet mode's, whose
# captain is present: bin/fm-afk-contract.sh mode), the bound is
# raised to FM_CODEX_WATCH_CHECKPOINT_AWAY (default 3600) when that is longer,
# so a parked main is not woken every few minutes; an engine turn that starts
# before the bound may finish after it. A close that carries a wake or a
# "supervision-host:" line other than the park boundary passes through as a
# wake; the boundary alone is the ordinary quiet checkpoint. On a home that
# does not run the host nothing below changes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
esac
SECONDS_ARG=$((10#$SECONDS_ARG))
[ "$SECONDS_ARG" -gt 0 ] || { echo "error: --seconds must be greater than zero" >&2; exit 2; }

# A checkpoint is neither an ordinary watcher start nor an Option B handling
# successor. It keeps an announced recovery episode stable while preserving the
# watcher's ordinary recovery of a generation that becomes pending.
export FM_WATCH_FOREGROUND_CHECKPOINT=1

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

# fm_exec_timed owns the bound: <signal> goes to the command's own process
# group at <seconds>, and KILL follows <grace-seconds> later. It prefers its
# perl watchdog, which never signals itself; uutils coreutils timeout (Ubuntu
# 26.04's default) receives its own non-TERM signal on Linux and KILLs the
# command at once, skipping the watcher's lock cleanup.
run_bounded() {  # <seconds> <signal> <grace-seconds> <command...>
  local seconds=$1 signal=$2 grace=$3
  shift 3
  ( FM_EXEC_TIMED_SIGNAL=$signal fm_exec_timed "$seconds" "$grace" "$@" )
}

# The watcher's grace is its lock-cleanup bound, never shorter than <floor>.
watcher_grace() {  # <floor>
  local floor=$1 bound=${FM_WATCHER_CLEANUP_LOCK_BOUND:-2}
  case "$bound" in
    ''|*[!0-9]*) bound=2 ;;
    *) bound=$((10#$bound)) ;;
  esac
  [ "$bound" -gt 0 ] || bound=2
  [ "$bound" -gt "$floor" ] || bound=$floor
  printf '%s\n' "$bound"
}

positive_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
if fm_supervision_host_enabled "$CONFIG" codex; then
  BOUND=$SECONDS_ARG
  if [ -f "$STATE/.afk-contract" ] \
    && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    AWAY_BOUND=$(positive_or "${FM_CODEX_WATCH_CHECKPOINT_AWAY:-}" 3600)
    [ "$AWAY_BOUND" -le "$BOUND" ] 2>/dev/null || BOUND=$AWAY_BOUND
  fi
  # The host's park boundary stays below the 28800-second registration.
  [ "$BOUND" -lt 27000 ] 2>/dev/null || BOUND=27000
  LIMIT=$(( BOUND + $(positive_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200) + $(positive_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30) ))
  set +e
  # The host ends its own park; the outer bound only catches a host that
  # outlived every one of its own bounds.
  FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=$BOUND FM_SUPERVISION_HOST_PARK_LIMIT=$LIMIT \
    run_bounded $((LIMIT + 120)) TERM 30 "$SCRIPT_DIR/fm-supervision-host.sh" park >"$OUT" 2>"$ERR"
  RC=$?
  set -e
  if grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT" 2>/dev/null \
    | grep -Ev '^supervision-host: cycle boundary' >/dev/null; then
    grep -Ev '^watcher: (started|attached) ' "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi
  if grep -E '^supervision-host: cycle boundary' "$OUT" >/dev/null 2>&1; then
    printf 'checkpoint: no actionable wake within %ss\n' "$BOUND"
    exit 124
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  if fm_timed_out "$RC"; then
    echo "checkpoint: the supervision host outlived its own bound of ${BOUND}s" >&2
    exit 1
  fi
  [ "$RC" -ne 0 ] || RC=1
  exit "$RC"
fi

set +e
# Interrupt the checkpoint's active check group so the watcher's native EXIT cleanup can release its lock; ordinary watcher shutdown still uses TERM.
run_bounded "$SECONDS_ARG" INT "$(watcher_grace 5)" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
RC=$?
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if fm_timed_out "$RC"; then
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
