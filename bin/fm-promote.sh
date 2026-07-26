#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Promotion updates the
# durable backlog kind through the configured tasks-axi backend before flipping
# kind= to ship in state/<task-id>.meta. The backlog schema and backend selection
# are owned by .tasks.toml, docs/configuration.md, and current tasks-axi help.
# Promotion refuses without metadata mutation when config/backlog-backend selects
# manual, when the configured tasks-axi backend is unavailable or incompatible,
# or when the durable backlog record for the task is missing. If the final
# metadata replacement fails, or a HUP/INT/TERM interrupt arrives after the
# durable write, the backlog kind is rolled back to scout and the script exits
# nonzero rather than claiming promotion succeeded; an interrupt is reported as an
# interrupt and a failed rollback as a durable divergence.
# After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

if fm_backlog_backend_manual "$CONFIG"; then
  echo "error: task $ID cannot be promoted while config/backlog-backend selects manual; metadata left unchanged" >&2
  exit 1
fi
if ! fm_tasks_axi_compatible; then
  echo "error: task $ID cannot be promoted because the configured tasks-axi backlog backend is unavailable or incompatible; metadata left unchanged" >&2
  exit 1
fi

SHOW_OUT=''
if ! SHOW_OUT=$(tasks-axi show "$ID" --file "$BACKLOG" 2>&1); then
  echo "error: no durable backlog record for task $ID at $BACKLOG; metadata left unchanged" >&2
  [ -n "$SHOW_OUT" ] && printf '%s\n' "$SHOW_OUT" >&2
  exit 1
fi

TMP="$META.tmp"
BACKLOG_UPDATED=0

promote_cleanup() {
  rm -f "$TMP"
}

promote_interrupt() {
  local sig=$1
  rm -f "$TMP"
  if [ "$BACKLOG_UPDATED" -eq 1 ]; then
    if tasks-axi update "$ID" --kind scout --file "$BACKLOG" >/dev/null 2>&1; then
      echo "error: promotion of $ID interrupted by SIG$sig; durable backlog kind rolled back to scout" >&2
    else
      echo "error: promotion of $ID interrupted by SIG$sig and durable backlog rollback also failed; backlog may say ship while metadata says scout" >&2
    fi
  else
    echo "error: promotion of $ID interrupted by SIG$sig; metadata left unchanged" >&2
  fi
  trap - EXIT HUP INT TERM
  kill -s "$sig" "$$"
}

trap promote_cleanup EXIT
trap 'promote_interrupt HUP' HUP
trap 'promote_interrupt INT' INT
trap 'promote_interrupt TERM' TERM
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"

UPDATE_OUT=''
if ! UPDATE_OUT=$(tasks-axi update "$ID" --kind ship --file "$BACKLOG" 2>&1); then
  echo "error: durable backlog update failed for task $ID; metadata left unchanged" >&2
  [ -n "$UPDATE_OUT" ] && printf '%s\n' "$UPDATE_OUT" >&2
  exit 1
fi
BACKLOG_UPDATED=1

if ! mv "$TMP" "$META"; then
  ROLLBACK_OUT=''
  if ROLLBACK_OUT=$(tasks-axi update "$ID" --kind scout --file "$BACKLOG" 2>&1); then
    echo "error: metadata update failed for task $ID; durable backlog kind rolled back to scout" >&2
  else
    echo "error: metadata update failed for task $ID and durable backlog rollback also failed; backlog may say ship while metadata says scout" >&2
    [ -n "$ROLLBACK_OUT" ] && printf '%s\n' "$ROLLBACK_OUT" >&2
  fi
  exit 1
fi
trap - EXIT HUP INT TERM

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (durable backlog updated; teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
