#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Promotion updates the
# durable backlog kind through the configured tasks-axi backend before flipping
# kind= to ship in state/<task-id>.meta. The backlog schema and backend selection
# are owned by .tasks.toml, docs/configuration.md, and current tasks-axi help.
# Promotion refuses without metadata mutation when config/backlog-backend selects
# manual, when the configured tasks-axi backend is unavailable or incompatible,
# or when the durable backlog record for the task is missing. Once the durable
# write is attempted, every failure and every HUP/INT/TERM interrupt reconciles the
# two records from what they actually say rather than from how far the script got,
# because neither a backend exit status nor a progress flag can be trusted after a
# signal: if the metadata already says ship the promotion stands and both records
# stay at ship, otherwise the durable kind is reset to scout - a no-op when the
# write never landed, and the repair when a killed or failing backend committed it
# anyway. A reset that itself fails is reported as a durable divergence carrying
# the backend's own reason. All of these paths exit nonzero rather than claiming
# promotion succeeded.
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
META_HAD_SHIP=0
if grep -qx 'kind=ship' "$META"; then
  META_HAD_SHIP=1
fi

promote_cleanup() {
  rm -f "$TMP"
}

promote_metadata_says_ship() {
  [ "$META_HAD_SHIP" -eq 0 ] && grep -qx 'kind=ship' "$META" 2>/dev/null
}

promote_reconcile() {
  local context=$1 out=''
  if promote_metadata_says_ship; then
    echo "error: $context; the metadata swap had already completed, so both records stay at ship and the ship instructions were not sent" >&2
    return 0
  fi
  if out=$(tasks-axi update "$ID" --kind scout --file "$BACKLOG" 2>&1); then
    echo "error: $context; durable backlog kind reset to scout to match the unchanged metadata" >&2
  else
    echo "error: $context and the durable backlog reset to scout failed; the backlog may say ship while the metadata says scout" >&2
    [ -n "$out" ] && printf '%s\n' "$out" >&2
  fi
  return 0
}

promote_interrupt() {
  local sig=$1
  rm -f "$TMP"
  promote_reconcile "promotion of $ID interrupted by SIG$sig"
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
  [ -n "$UPDATE_OUT" ] && printf '%s\n' "$UPDATE_OUT" >&2
  promote_reconcile "durable backlog update failed for task $ID"
  exit 1
fi

if ! mv "$TMP" "$META"; then
  promote_reconcile "metadata update failed for task $ID"
  exit 1
fi
trap - EXIT HUP INT TERM

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (durable backlog updated; teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
