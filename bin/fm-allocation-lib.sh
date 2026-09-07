#!/usr/bin/env bash
# fm-allocation-lib.sh - the task allocation-ownership contract (one owner).
#
# WHY. A ship or scout task's worktree, and a secondmate's home, come from a
# pool: `treehouse get` hands out a numbered slot path and `treehouse return`
# hands it back. The path is therefore REUSED. Nothing in a slot path, a pane
# label, or a task-ID lease says which task currently holds it, and firstmate's
# spawns take no Treehouse lease at all (`treehouse status --json` reports empty
# lease fields for them), so `treehouse return --if-lease-id` cannot bind one
# either. The only durable task-to-allocation link is the `worktree=` (or, for a
# secondmate, `home=`) line in that task's own `state/<id>.meta`.
#
# THE HAZARD. Two task records can name one path: a stale record left by a task
# whose slot was already returned and re-handed, and the live record of the task
# now working in it. Cleanup of the STALE record would then delete the LIVE
# task's branch and `treehouse return --force` the allocation out from under it,
# because every cleanup step reads only its own record. A scout skips the
# landed-work check after its report exists, and `--force` skips it outright, so
# neither is a backstop here.
#
# THE CONTRACT. Before a caller returns, removes, or otherwise mutates an
# allocation, it must be able to prove the allocation belongs to the task it is
# acting for. This library states the one thing that provably disproves it:
#
#   fm_allocation_conflicts <state-dir> <task-id> <path>
#     Prints "<peer-task-id>\t<field>" for every OTHER current record in
#     <state-dir> that names <path> as its own allocation, and returns 0 when at
#     least one such record exists (1 when none does).
#
# A conflict is a REFUSAL, never an authorization. The direction matters: no
# conflict does not prove ownership, it only means no other record contradicts
# it, so callers keep every check they already run. Deliberately NOT accepted as
# proof of ownership, per the audit: a matching path on its own, a pane label, a
# dead endpoint, blank Treehouse lease fields, and a firstmate task-ID lease
# (bin/fm-lease-lib.sh, which arbitrates between the two supervision ACTORS in
# one home, not between tasks over one allocation).
#
# `--force` MUST NOT bypass this. Force means "discard the work in MY OWN
# allocation"; it has never meant "act on a record that may not be mine".
#
# SCOPE. This is a guard on MUTATION - the paths that return a Treehouse slot or
# destroy a worktree - not on record creation. Refusing a spawn whose pooled path
# an older record still names was considered and deliberately left out: it does
# not prevent any destructive act the mutation guard below does not already
# refuse, and firstmate's spawn fixtures legitimately hand one fake worktree to
# several task ids, so the refusal fired where nothing was at risk.
#
# RECORDS-ONLY RETIREMENT. A contested allocation must not deadlock cleanup. A
# Herdr session restart frees the pooled slot of every live task while its record
# survives, so the next `treehouse get` can re-hand a slot a stale record still
# names - after which, if a conflict simply refused the whole teardown, NEITHER
# task could ever be cleaned up. So a conflict refuses only the ALLOCATION half:
# the caller leaves the worktree, its branch, and the pooled slot completely
# alone, and still retires the records it exclusively owns - its own metadata,
# status log, steering inbox, poll and hook artifacts, busy state, backlog row,
# and its own endpoint. Nothing outside this task's own records is touched, so
# the contested slot and the peer record both survive untouched for the peer's
# own cleanup or for a human to reconcile. Once one side retires, the other is
# the sole claimant and its next teardown proceeds in full, normally.
#
# This is not a bypass and there is no flag for it: the mutation stays refused,
# unconditionally, and nothing is deleted on age, silence, or a dead endpoint.
#
# Path identity is compared on the resolved real path when the path exists, so a
# symlinked pool root, `/tmp` vs `/private/tmp`, and a trailing slash cannot hide
# a collision. A path that no longer exists is compared literally, which is the
# right direction: an already-returned slot still conflicts by its recorded name.
#
# Both `worktree=` and `home=` are read from peer records because those are the
# two allocation fields firstmate records - an ordinary task's pooled worktree
# and a secondmate's pooled home - and a collision between the two kinds is as
# destructive as one within a kind.
#
# Requires fm_meta_get from bin/fm-backend.sh, the one owner of reading a task
# metadata field; it is sourced here when the caller has not already loaded it.

if ! command -v fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-backend.sh"
fi

# fm_allocation_identity <path>
# The comparable identity of an allocation path: its resolved real path when the
# directory exists, else the path as recorded. Empty input returns 1.
fm_allocation_identity() {
  local path=$1 real=''
  [ -n "$path" ] || return 1
  if [ -d "$path" ]; then
    real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || real=''
  fi
  printf '%s\n' "${real:-$path}"
}

# fm_allocation_conflicts <state-dir> <task-id> <path>
# Prints "<peer-task-id>\t<field>" for every other record in <state-dir> that
# claims <path>. Returns 0 when at least one conflict was printed, else 1.
fm_allocation_conflicts() {
  local state=$1 id=$2 path=$3 want meta peer field value found=1
  [ -n "$path" ] || return 1
  [ -d "$state" ] || return 1
  want=$(fm_allocation_identity "$path") || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    peer=$(basename "$meta" .meta)
    [ "$peer" != "$id" ] || continue
    for field in worktree home; do
      value=$(fm_meta_get "$meta" "$field")
      [ -n "$value" ] || continue
      [ "$(fm_allocation_identity "$value")" = "$want" ] || continue
      printf '%s\t%s\n' "$peer" "$field"
      found=0
      break
    done
  done
  return "$found"
}

# fm_allocation_exclusive <state-dir> <task-id> <path> <what>
# The shared decision. Returns 0 when <task-id> is the only record claiming
# <path>, so the caller may mutate the allocation. Returns 1, after printing one
# notice line naming every other claimant, when it is not: the caller must then
# leave the worktree, its branch, and the pooled slot completely alone and retire
# only the records this task exclusively owns. <what> names the allocation in the
# caller's own words, e.g. "worktree", "home", or "child worktree".
fm_allocation_exclusive() {
  local state=$1 id=$2 path=$3 what=$4 conflicts peers peer field
  conflicts=$(fm_allocation_conflicts "$state" "$id" "$path") || return 0
  peers=
  while IFS=$'\t' read -r peer field; do
    [ -n "$peer" ] || continue
    peers="${peers:+$peers, }$peer ($field=)"
  done <<< "$conflicts"
  echo "notice: task $id's $what $path is also recorded by $peers, so a matching path cannot say which task owns it; retiring only $id's own records and leaving the allocation, its branch, and the pooled slot to the other record." >&2
  return 1
}
