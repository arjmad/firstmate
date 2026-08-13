#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Promotion also updates the DURABLE backlog kind through the configured tasks-axi
# backend before flipping kind= in the meta, so the two records cannot diverge:
# metadata alone saying ship while the backlog still records a scout is what makes
# a promoted ship keep being measured against the scout report contract. The
# schema and backend selection are owned by .tasks.toml, docs/configuration.md,
# and current tasks-axi help. When config/backlog-backend selects manual, or the
# configured tasks-axi backend is unavailable or incompatible, promotion warns
# that the durable record must be updated by hand and proceeds - refusing there
# would make promotion impossible whenever the backend is momentarily absent.
# Promotion refuses without touching metadata only when a present, readable
# backlog has no durable record for the task.
# Once the durable write is attempted, every failure and every HUP/INT/TERM
# reconciles the two records from what they ACTUALLY say rather than from how far
# the script got, because neither an exit status nor a progress flag can be
# trusted after a signal: if the metadata no longer says scout the swap landed, so
# the promotion stands, both records stay at ship, and the worker next-command is
# still printed so an interrupted run can be finished by hand; otherwise the
# durable kind is reset to scout - a no-op when the write never landed, and the
# repair when a killed or failing backend committed it anyway. A reset that itself
# fails is reported as a durable divergence carrying the backend's own reason.
# All of those paths exit nonzero rather than claiming promotion succeeded.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# Durable-backlog preflight: every refusal below leaves metadata untouched.
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# A home whose backlog backend is manual, unavailable, or incompatible has no
# programmatic writer for the durable record. That is a SUPPORTED configuration
# (AGENTS.md section 10), so promotion still proceeds there rather than becoming
# impossible - but it says loudly what must be hand-edited, because an unnoticed
# divergence is exactly what this synchronization exists to prevent.
DURABLE_BACKLOG=1
if fm_backlog_backend_manual "$CONFIG"; then
  DURABLE_BACKLOG=0
  echo "warning: config/backlog-backend selects manual, so the durable backlog kind for $ID is NOT updated automatically; hand-edit its backlog row to (kind: ship) or the promoted task keeps being measured against the scout contract" >&2
elif ! fm_tasks_axi_compatible; then
  DURABLE_BACKLOG=0
  echo "warning: the configured tasks-axi backlog backend is unavailable or incompatible, so the durable backlog kind for $ID is NOT updated automatically; hand-edit its backlog row to (kind: ship) or the promoted task keeps being measured against the scout contract" >&2
elif [ ! -f "$BACKLOG" ]; then
  # No backlog FILE at all means this home keeps no durable backlog here, which
  # is the same "nothing to synchronize" situation as a manual backend. A
  # PRESENT backlog missing this task's row is different - that is the records
  # already disagreeing - and is refused below.
  DURABLE_BACKLOG=0
  echo "warning: no durable backlog at $BACKLOG, so the durable kind for $ID is NOT updated automatically" >&2
fi
if [ "$DURABLE_BACKLOG" = 1 ]; then
  SHOW_OUT=''
  if ! SHOW_OUT=$(tasks-axi show "$ID" --file "$BACKLOG" 2>&1); then
    echo "error: no durable backlog record for task $ID at $BACKLOG; metadata left unchanged" >&2
    [ -n "$SHOW_OUT" ] && printf '%s\n' "$SHOW_OUT" >&2
    exit 1
  fi
fi

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
promote_next_command() {
  local home_q
  home_q=$(printf '%q' "$FM_HOME")
  echo "next: FM_HOME=$home_q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
}

# Truth, not bookkeeping: the metadata file itself says whether the swap landed.
promote_swap_landed() {
  [ -f "$META" ] && ! grep -qx 'kind=scout' "$META"
}

promote_reconcile() {
  local context=$1 out=''
  if promote_swap_landed; then
    echo "error: $context; the metadata swap had already completed, so both records stay at ship and the promotion stands - only the ship instructions are unsent" >&2
    promote_next_command >&2
    return 0
  fi
  if [ "$DURABLE_BACKLOG" != 1 ]; then
    echo "error: $context; the durable backlog was never updated automatically in this home, so only the metadata needed reverting" >&2
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
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  promote_reconcile "promotion of $ID interrupted by SIG$sig"
  trap - EXIT HUP INT TERM
  kill -s "$sig" "$$"
}

trap 'promote_interrupt HUP' HUP
trap 'promote_interrupt INT' INT
trap 'promote_interrupt TERM' TERM

# Durable record first, metadata second: a crash between them leaves the backlog
# ahead of the meta, which reconciliation can repair, rather than a promoted task
# whose durable record still calls it a scout.
UPDATE_OUT=''
if [ "$DURABLE_BACKLOG" = 1 ] \
  && ! UPDATE_OUT=$(tasks-axi update "$ID" --kind ship --file "$BACKLOG" 2>&1); then
  [ -n "$UPDATE_OUT" ] && printf '%s\n' "$UPDATE_OUT" >&2
  promote_reconcile "durable backlog update failed for task $ID"
  exit 1
fi
if ! mv "$TMP" "$META"; then
  promote_reconcile "metadata update failed for task $ID"
  exit 1
fi
trap - HUP INT TERM
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

if [ "$DURABLE_BACKLOG" = 1 ]; then
  echo "promoted $ID to ship mode=$MODE yolo=$YOLO (durable backlog updated; teardown protection restored)"
else
  echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored; durable backlog row still needs a manual (kind: ship) edit)"
fi
promote_next_command
