#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh under its channel contract;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# The one merge that queues nothing is an attended merge main made itself in a
# main home: its own fm-pr-merge.sh output is the receipt, and a wake would only
# hand the same event back to it as a second turn. Every other merge keeps its
# wake, because there the queue is the record the captain or branch acts on.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-lease-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
#   branch - the attended supervision branch performed a standing merge
#          (bin/fm-pr-merge.sh header). A main home records it as a silent
#          routine row in the branch outcome store (bin/fm-branch-outcome.sh)
#          instead of a check wake, so main gets a landed note and no turn,
#          and the branch closes the task in the turn that merged it; a
#          secondmate home reports upward exactly as for self. A poll of
#          that merge still wakes main, tagged branch, so a merge the branch
#          could not close in its own turn is still closed.
# Optional <authority> is away, attended, branch, or external (the retired yolo and
# away-grant values are still accepted for a persisted authority written before
# the words model landed). Away, branch, external, and the retired tags are appended to
# the ledger line; attended remains untagged. The merge entrypoint supplies its
# authority after forge acceptance, while the poll supplies the persisted
# identity-bound value or external when no matching record proves that this
# home authorized the merge.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local self_rc=0 destination='' line lock status=0 wake=true
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll|branch) ;; *) return 2 ;; esac
  case "$authority" in
    away|branch|external|yolo|away-grant) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $FM_PR_URL$suffix"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
    if [ "$origin" = self ] && [ "$(fm_lease_actor 2>/dev/null)" = main ]; then
      case "$authority" in attended|'') wake=false ;; esac
    fi
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$(status_stamp_line "$line")" || status=1
  fi
  # Only the branch's own merge run is silent: the branch is there to close
  # the task. A poll that observes the merge first (a queued merge, a race, or
  # a run that died) still wakes main, so someone closes it.
  if [ "$status" -eq 0 ] && [ "$origin" = branch ] && [ -z "$destination" ]; then
    FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-branch-outcome.sh" append \
      --task "$id" --verdict routine --silent true \
      --summary "merged $id $FM_PR_URL under standing authority" \
      --wake "check: merge landed: $id $FM_PR_URL$suffix" >/dev/null || status=1
  elif [ "$status" -eq 0 ] && [ "$wake" = true ] \
    && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-fleet-ledger.sh" merged "$id" pr "$FM_PR_URL" || true
  return "$status"
}
