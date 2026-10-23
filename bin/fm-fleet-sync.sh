#!/usr/bin/env bash
# Refresh project clones: fast-forward the checked-out local default branch to
# origin/<default> when safe, and prune local branches whose upstream tracking
# branch is gone, whose commits provably landed on origin/<default>, and that no
# worktree still needs.
# Self-heals the one unambiguously safe drift: a clean, detached HEAD that holds
# no unique commits (it is an ancestor of origin/<default>) and whose <default>
# branch is free to check out is re-attached and then fast-forwarded ("recovered:").
# Every other off-default state - a non-default named branch, a detached HEAD with
# unique commits, a dirty tree, or a diverged default - may hold real work, so it
# is left untouched and reported as a quantified, loud "STUCK: ... N commits behind
# ... - needs attention" warning rather than a quiet drift. Nothing is ever forced,
# stashed, or discarded.
# Still skips (benignly) local-only/no-origin projects, missing remotes/branches,
# and fetch failures. A project whose registry entry bin/fm-project-mode.sh
# refuses is skipped too, naming that command so its refusal is readable, rather
# than synced under a guessed posture.
# A candidate under projects/ must be the root of its own work tree: git discovery
# walks up, so a plain nested directory would otherwise resolve to the enclosing
# repository (the firstmate checkout) and be synced under that directory's label.
# Anything else is reported as "skipped: not a clone root" naming the repository
# that would have been touched. A candidate that has a .git yet yields no work
# tree (for example a stray core.bare=true) is a broken clone, reported STUCK
# with its core.bare and core.worktree values rather than as a benign skip.
# Pruning deletes a gone-upstream branch only when its commits are proven landed
# on origin/<default> (an ancestor, or a squash merge whose content is already
# there), and never the checked-out branch or a branch that still has a
# worktree, so it cannot discard unlanded work; set FM_FLEET_PRUNE=0 to disable it.
# When the fetch fails on an orphaned .git/packed-refs.lock (left by a ref rewrite
# killed mid-write - e.g. a timed-out bootstrap sync or a teardown process kill),
# it is retried with a bounded wait and removed only when provably stale; see
# fetch_with_packed_refs_lock_guard and the FM_FLEET_SYNC_PACKED_REFS_LOCK_* knobs.
# Live checkouts: after the projects/ clones, it also fast-forwards each live
# checkout the captain-private $FM_HOME/config/live-checkouts lists - a working
# copy outside projects/ that something actually runs from (a scheduled job's
# repo, a symlinked skills tree, a service's source). One entry per line:
#   <project> <path> [lock=<lock-path>] [capture=<dir>/:<command>] [post-update command...]
# Blank lines and lines starting with # are ignored; a leading ~/ in <path> or
# <lock-path> expands to $HOME. An absent file means no live checkouts.
# Each live checkout gets the same guards as a clone - clone root, origin, clean
# tree, on its default branch (or the safe detached-HEAD self-heal), merge
# --ff-only, else a loud STUCK line - but never branch pruning and never the
# registry posture check. A path that is this firstmate home is refused: Firstmate
# updates itself only through /updatefirstmate.
# lock=<lock-path> names a file or directory whose existence means the checkout is
# in use (a running job cycle); the sync waits while it exists - up to
# FM_LIVE_CHECKOUT_LOCK_WAIT_SECS (default 120, polling every
# FM_LIVE_CHECKOUT_LOCK_POLL_SECS, default 5) in the single-project form and not
# at all in the whole-fleet form - then reports "skipped: busy: ..." and leaves the
# checkout for the next sync.
# The post-update command runs through bash -c from the checkout's directory each
# time the checkout's HEAD differs from the commit it last succeeded for, which
# state/live-checkouts/<key> records. A first sighting with no record runs it only
# when this sync moved HEAD; otherwise it just records the current HEAD. A failed
# command reports STUCK and never records that HEAD, so the next sync retries it.
# Its output still goes to stderr, and a failure's STUCK line also ends with
# "; last output: " and the command's last POST_UPDATE_TAIL_LINES non-blank lines
# joined with " / ", so a relay that keeps only stdout still names the reason.
# capture=<dir>/:<command> is for a checkout whose tree is edited in place, such
# as a writable skills/ tree that a capture job commits as a PR. When the
# checkout is on its default branch and every uncommitted path (tracked edits
# and untracked files, ignored ones excluded) lies under <dir>/, the sync starts
# <command> (relative to the checkout, ~/ or absolute, no arguments) detached
# from the checkout's directory, in its own process group so a timed-out sync
# cannot kill it, and prints "capturing: ..." instead of a STUCK line. It
# starts once per edit state (HEAD, origin/<default> and the uncommitted content
# under <dir>/), logging to state/live-checkouts/<key>.capture.log. While that
# run is alive the checkout is deferred like a held lock ("skipped: busy:"), so
# no fast-forward or post-update runs under it. Once it has finished, the
# ordinary STUCK line returns with "; capture already ran for these edits (exit
# N, ...)", so a capture that did not clear the checkout still surfaces, and a
# new edit state after a failed capture starts another one under a STUCK line
# naming the failure. Edits outside <dir>/ are reported STUCK as before. <dir>
# must lie inside the checkout, and a <command> without a slash is ./<command>.
# The single-project form syncs the entries for that project name; the whole-fleet
# form syncs every entry after the clones.
# Scheduled form (--scheduled): bin/fm-watch.sh starts it detached once per
# scheduled interval, so a merge firstmate did not make still goes live. It is
# one whole-fleet sync under the home-scoped singleton lock
# $STATE/.fleet-sync-scheduled.lock (a run that finds it held exits at once),
# with its full stdout kept in $STATE/.fleet-sync-scheduled.log. Each STUCK line not already
# surfaced is appended to $STATE/fleet-sync-stuck, which the watcher claims and
# turns into one "check: fleet-sync: ..." wake; $STATE/.fleet-sync-surfaced
# holds the current STUCK set (post-update output tail removed), so an unchanged
# STUCK state wakes once, and one that clears and returns wakes again. Every
# other outcome, including a "skipped: busy:" lock, stays silent for the next run.
# --scheduled-interval prints the interval in seconds, 0 when off: the first
# non-blank, non-# line of $FM_HOME/config/fleet-sync-interval, else
# FM_FLEET_SYNC_INTERVAL, else 1800; "off" or 0 disables it, and a value below
# 300 is raised to 300.
# Usage: fm-fleet-sync.sh [<project-dir-or-name> | --scheduled | --scheduled-interval]
# The single-project form accepts either a path (absolute, or relative to the
# caller's cwd) or a bare "<name>"/"projects/<name>" form, resolved against
# this home's projects dir ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE).
# Bare names and "projects/<name>" forms prefer this home's projects dir before
# falling back to an explicit path. Example: from anywhere,
# `fm-fleet-sync.sh dotfiles-private` syncs just that one clone, same as
# passing its full projects/dotfiles-private path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LIVE_CHECKOUTS_FILE="$CONFIG/live-checkouts"
LIVE_RECORDS="$STATE/live-checkouts"
# Absolute, because a capture opens its log and status from the checkout.
case "$LIVE_RECORDS" in /*) ;; *) LIVE_RECORDS="$PWD/$LIVE_RECORDS" ;; esac
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# Inert unless FM_TIMING_LOG names a file; only the deferred network stage sets it.
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
FM_LOCK_LOG_PREFIX=fleet-sync
"$FM_ROOT/bin/fm-guard.sh" || true

# Bounded recovery for an orphaned .git/packed-refs.lock. A git ref rewrite
# (fetch --prune, branch -D, pack-refs) killed after creating the lock but before
# renaming it - e.g. bootstrap's fleet-sync timeout kill, or teardown's process
# kills - leaves a lock that makes the next sync's fetch fail with Git's
# "Unable to create '...packed-refs.lock': File exists". These knobs bound the
# patience-then-provably-stale-clear recovery; see fetch_with_packed_refs_lock_guard.
FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES:-3}
FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS:-1}
FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=${FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS:-30}
case "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 ;; esac
case "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS" in ''|*[!0-9]*) FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 ;; esac
if ! [[ "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
  echo "fleet-sync: invalid packed-refs lock retry wait '$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1
fi

LIVE_LOCK_WAIT_SECS=${FM_LIVE_CHECKOUT_LOCK_WAIT_SECS:-120}
LIVE_LOCK_POLL_SECS=${FM_LIVE_CHECKOUT_LOCK_POLL_SECS:-5}
case "$LIVE_LOCK_WAIT_SECS" in ''|*[!0-9]*) LIVE_LOCK_WAIT_SECS=120 ;; esac
case "$LIVE_LOCK_POLL_SECS" in ''|*[!0-9]*|0) LIVE_LOCK_POLL_SECS=5 ;; esac
# A failed post-update command's STUCK line carries this much of its output.
POST_UPDATE_TAIL_LINES=3
POST_UPDATE_TAIL_CHARS=200
# The current live checkout's capture=<dir>/:<command>; empty for clones.
CAPTURE_DIR=""
CAPTURE_CMD=""

SCHEDULED_INTERVAL_FILE="$CONFIG/fleet-sync-interval"
SCHEDULED_INTERVAL_DEFAULT=1800
SCHEDULED_INTERVAL_MIN=300
SCHEDULED_LOCK="$STATE/.fleet-sync-scheduled.lock"
SCHEDULED_LOG="$STATE/.fleet-sync-scheduled.log"
SCHEDULED_SURFACED="$STATE/.fleet-sync-surfaced"
SCHEDULED_STUCK="$STATE/fleet-sync-stuck"

usage() {
  echo "usage: fm-fleet-sync.sh [<project-dir-or-name> | --scheduled | --scheduled-interval]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

# scheduled_interval: the effective scheduled-sync interval in seconds, 0 when
# off. config/fleet-sync-interval wins over FM_FLEET_SYNC_INTERVAL; its first
# line that is neither blank nor a # comment is the value.
scheduled_interval() {
  local raw from
  if [ -f "$SCHEDULED_INTERVAL_FILE" ]; then
    from=$SCHEDULED_INTERVAL_FILE
    raw=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$SCHEDULED_INTERVAL_FILE" 2>/dev/null | head -n 1 | tr -d '[:space:]')
  else
    from=FM_FLEET_SYNC_INTERVAL
    raw=${FM_FLEET_SYNC_INTERVAL:-}
  fi
  case "$raw" in
    '') echo "$SCHEDULED_INTERVAL_DEFAULT" ;;
    off|0) echo 0 ;;
    *[!0-9]*)
      echo "fleet-sync: invalid scheduled interval '$raw' in $from; using ${SCHEDULED_INTERVAL_DEFAULT}s" >&2
      echo "$SCHEDULED_INTERVAL_DEFAULT"
      ;;
    *)
      raw=$((10#$raw))
      if [ "$raw" -lt "$SCHEDULED_INTERVAL_MIN" ]; then
        echo "fleet-sync: scheduled interval ${raw}s in $from is below the ${SCHEDULED_INTERVAL_MIN}s floor; using ${SCHEDULED_INTERVAL_MIN}s" >&2
        raw=$SCHEDULED_INTERVAL_MIN
      fi
      echo "$raw"
      ;;
  esac
}

# stuck_key <line>: a STUCK line without its post-update output tail, so the same
# failure with different log noise is not surfaced again.
stuck_key() {
  printf '%s\n' "${1%%; last output: *}"
}

# replace_file <path> <content>: atomically replace <path> with <content> plus a
# trailing newline when <content> is non-empty.
replace_file() {
  local path=$1 content=$2 tmp
  tmp="$path.tmp.$$"
  if { [ -z "$content" ] || printf '%s\n' "$content"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$path"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# run_scheduled: one whole-fleet sync for the watcher's schedule (see the
# header). It queues only STUCK lines not already surfaced for firstmate.
run_scheduled() {
  local out line key new="" surfaced="" current=""
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  mkdir -p "$STATE"
  fm_lock_try_acquire "$SCHEDULED_LOCK" || return 0
  # shellcheck disable=SC2064 # bind this lock path now
  trap "fm_lock_release '$SCHEDULED_LOCK'" EXIT
  out=$(mktemp "$STATE/.fleet-sync-scheduled.out.XXXXXX") || return 0
  "$SCRIPT_DIR/fm-fleet-sync.sh" </dev/null >"$out" 2>/dev/null || true
  mv -f "$out" "$SCHEDULED_LOG" 2>/dev/null || { rm -f "$out"; return 0; }
  [ ! -f "$SCHEDULED_SURFACED" ] || surfaced=$(cat "$SCHEDULED_SURFACED" 2>/dev/null || true)
  while IFS= read -r line; do
    case "$line" in *': STUCK:'*) ;; *) continue ;; esac
    key=$(stuck_key "$line")
    current="$current$key"$'\n'
    if ! printf '%s\n' "$surfaced" | grep -Fxq -- "$key"; then
      new="$new$line"$'\n'
    fi
  done < "$SCHEDULED_LOG"
  if [ -n "$new" ]; then
    # The watcher claims this file by renaming it, so read-then-replace here can
    # at worst repeat a line it already claimed, never lose one.
    # The surfaced set is not advanced unless the lines reached the watcher's
    # file, so a failed write is retried by the next run.
    replace_file "$SCHEDULED_STUCK" "$({ [ ! -f "$SCHEDULED_STUCK" ] || cat "$SCHEDULED_STUCK"; printf '%s' "$new"; })" \
      || return 0
  fi
  replace_file "$SCHEDULED_SURFACED" "$current" || true
  return 0
}

case "${1:-}" in
  --scheduled-interval)
    scheduled_interval
    exit 0
    ;;
  --scheduled)
    run_scheduled
    exit 0
    ;;
  -*)
    usage
    exit 1
    ;;
esac

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

# resolve_project_arg <arg>: accept a path (used as-is when it already exists)
# or a bare/"projects/<name>" project name, resolved against $PROJECTS. Falls
# back to the original argument unresolved so a genuinely bad path still hits
# sync_project's existing "not a directory" skip.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$arg"
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# True when git stderr shows the packed-refs.lock "File exists" race. The lock
# path can appear anywhere in the message (git prefixes it with the failed ref op,
# e.g. "could not delete reference ...:"). Other "File exists" errors must not match.
is_packed_refs_lock_error() {
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*packed-refs\\.lock['\"]: File exists"
}

# Absolute path to $PROJ's packed-refs.lock, or empty when it cannot be resolved.
packed_refs_lock_path() {
  local lock abs
  lock=$(git -C "$PROJ" rev-parse --git-path packed-refs.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs=$(cd "$PROJ" && pwd -P) || return 1
      printf '%s/%s\n' "$abs" "$lock"
      ;;
  esac
}

# Run `git -C "$PROJ" fetch origin --prune --quiet`, tolerating an orphaned
# packed-refs.lock left by a killed ref rewrite. Sets FETCH_OUTPUT to the git
# command's combined output and returns its exit status. On the packed-refs.lock
# signature ONLY: retry up to FLEET_SYNC_PACKED_REFS_LOCK_RETRIES times (a
# transient lock self-clears as the owning process exits), then - only if the lock
# is provably stale per fm-lock-lib.sh (still present, mtime age past the
# threshold, no lsof holder of the lock or the clone worktree $PROJ) - remove it
# and retry once more. A live lock, an unprovable one, or any other failure keeps
# today's behavior. Every wait, retry, and removal prints to stderr, and a
# successful recovery also prints one "$label: recovered: ..." summary to stdout so
# a session-start refresh (which discards fleet-sync stderr) still surfaces it.
fetch_with_packed_refs_lock_guard() {
  local rc attempt=0 lock lock_desc
  FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
  [ "$rc" -eq 0 ] && return 0
  is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"

  lock=$(packed_refs_lock_path) || lock=""
  lock_desc=${lock:-packed-refs.lock}
  while [ "$attempt" -lt "$FLEET_SYNC_PACKED_REFS_LOCK_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    echo "$label: fetch blocked by packed-refs lock ($lock_desc); waiting ${FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES}) (owning process may be exiting)" >&2
    sleep "$FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS"
    FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$label: fetch succeeded on retry; packed-refs lock cleared on its own" >&2
      # One stdout summary so a session-start refresh (which discards fleet-sync
      # stderr and relays only stdout) still surfaces the recovery.
      echo "$label: recovered: packed-refs lock cleared on its own during retry"
      return 0
    fi
    is_packed_refs_lock_error "$FETCH_OUTPUT" || return "$rc"
  done

  # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
  # The companion liveness dir is $PROJ (the clone worktree): a live `git -C "$PROJ"`
  # keeps its cwd there even in the narrow window after it closes packed-refs.lock
  # and before it exits, so lsof on $PROJ still catches a holder the lock-file check
  # alone would miss.
  lock=$(packed_refs_lock_path) || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    if fm_lock_is_provably_stale "$lock" "$PROJ" "$FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS"; then
      if ! rm -f "$lock"; then
        echo "$label: failed to remove provably-stale packed-refs lock $lock; leaving it in place" >&2
        return "$rc"
      fi
      echo "$label: removed provably-stale packed-refs lock $lock (age >= ${FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS}s, no live holder) and retrying fetch" >&2
      FETCH_OUTPUT=$(git -C "$PROJ" fetch origin --prune --quiet 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "$label: fetch succeeded after stale packed-refs lock cleanup" >&2
        echo "$label: recovered: removed a stale packed-refs lock (no live holder)"
        return 0
      fi
      return "$rc"
    fi
    echo "$label: fetch blocked by packed-refs lock $lock that persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$rc"
  fi
  echo "$label: fetch packed-refs lock signature persisted across ${FLEET_SYNC_PACKED_REFS_LOCK_RETRIES} retries even after the lock file disappeared" >&2
  return "$rc"
}

# Positive evidence that <branch>'s commits landed on <base>: its tip is an
# ancestor of <base>, or - after a squash merge, where it never is - merging it
# into <base> from their real merge base adds no tree change, the same
# containment proof bin/fm-teardown.sh's content_in_default applies before it
# removes a branch. A conflict or an unreadable ref is not evidence.
branch_landed_on() {  # <branch> <base>
  local branch=$1 base=$2 base_tree merged_tree
  git -C "$PROJ" merge-base --is-ancestor "refs/heads/$branch" "$base" 2>/dev/null && return 0
  base_tree=$(git -C "$PROJ" rev-parse --quiet --verify "$base^{tree}" 2>/dev/null) || return 1
  merged_tree=$(git -C "$PROJ" merge-tree --write-tree "$base" "refs/heads/$branch" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$merged_tree" | head -1)" = "$base_tree" ]
}

prune_gone_branches() {
  # Delete local branches whose upstream tracking branch is gone and whose
  # commits provably landed on origin/<default> (branch_landed_on), as long as
  # nothing still needs them. A gone upstream alone proves nothing - a remote
  # branch can be deleted unmerged, and a branch made outside task teardown
  # never passed its landed-work check - so a branch without that proof is kept
  # and named on stderr. Never the checked-out branch, and never a branch that
  # still has a worktree (a live or not-yet-torn-down task). With no readable
  # origin/<default> nothing is pruned. Set FM_FLEET_PRUNE=0 to skip pruning
  # entirely.
  [ "${FM_FLEET_PRUNE:-1}" != "0" ] || return 0

  local worktree_branches current refline branch track default base
  default=$(default_branch) || return 0
  base="refs/remotes/origin/$default"
  git -C "$PROJ" rev-parse --verify --quiet "$base^{commit}" >/dev/null || return 0
  worktree_branches=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p')
  current=$(git -C "$PROJ" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

  while IFS= read -r refline; do
    branch=${refline%% *}
    track=${refline#* }
    [ "$track" = "[gone]" ] || continue
    [ -n "$branch" ] || continue
    [ "$branch" != "$current" ] || continue
    if printf '%s\n' "$worktree_branches" | grep -Fxq -- "$branch"; then
      continue
    fi
    if ! branch_landed_on "$branch" "$base"; then
      echo "$label: kept $branch: its upstream is gone but its commits are not proven landed on origin/$default" >&2
      continue
    fi
    if git -C "$PROJ" branch -D -- "$branch" >/dev/null 2>&1; then
      echo "$label: pruned $branch"
    fi
  done < <(git -C "$PROJ" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null)
}

# True when some worktree of $PROJ has $DEFAULT checked out (so we cannot attach
# to it here). The current worktree is detached when this is consulted, so any
# match is necessarily another worktree.
default_checked_out_elsewhere() {
  git -C "$PROJ" worktree list --porcelain 2>/dev/null \
    | sed -n 's#^branch refs/heads/##p' \
    | grep -Fxq -- "$DEFAULT"
}

local_default_safe_for_recovery() {
  ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null \
    || git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE" 2>/dev/null
}

# Human-readable name for the unsafe state the clone is in, used in the STUCK
# warning. Reads $cur (current branch, empty when detached), $dirty, and the
# HEAD-vs-$BASE ancestry to pick the most informative description.
stuck_state() {
  local s
  if [ -n "$cur" ]; then
    s="branch $cur"
  elif [ "$dirty" = yes ]; then
    s="detached HEAD"
  elif ! git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null; then
    s="detached HEAD with unique commits"
  elif default_checked_out_elsewhere; then
    s="detached HEAD ($DEFAULT checked out in another worktree)"
  elif ! local_default_safe_for_recovery; then
    s="detached HEAD (local $DEFAULT diverged from $BASE)"
  else
    s="detached HEAD"
  fi
  [ "$dirty" = no ] || s="$s with uncommitted changes"
  printf '%s\n' "$s"
}

# Loud, quantified report for a clone we deliberately leave untouched. Includes
# how far behind origin/<default> it is, so a chronically-stuck clone is visibly
# distinct from a benign one-off skip.
report_stuck() {
  local state=$1 suffix=${2:-} behind
  behind=$(git -C "$PROJ" rev-list --count "HEAD..$BASE" 2>/dev/null) || behind="?"
  echo "$label: STUCK: on $state, $behind commits behind $BASE - needs attention$suffix"
}

# capture_paths_only: true when the checkout has uncommitted paths - tracked
# edits against HEAD and untracked files, ignored files excluded - and all of
# them lie under $CAPTURE_DIR; sets CAPTURE_COUNT to how many there are.
capture_paths_only() {
  local path n=0
  while IFS= read -r -d '' path; do
    case "$path" in "$CAPTURE_DIR"*) n=$((n + 1)) ;; *) return 1 ;; esac
  done < <({ git -C "$PROJ" diff -z --name-only --no-renames HEAD
    git -C "$PROJ" ls-files -z --others --exclude-standard; } 2>/dev/null | sort -zu)
  CAPTURE_COUNT=$n
  [ "$n" -gt 0 ]
}

# capture_fingerprint: one hash of the edit state a capture is started for, so
# an unchanged state never starts a second run. It includes origin/<default>
# because a capture is built on it: after a merge the edits need a fresh capture
# before they can land.
capture_fingerprint() {
  local untracked
  untracked=$(git -C "$PROJ" -c core.quotePath=false ls-files --others --exclude-standard -- "$CAPTURE_DIR" 2>/dev/null)
  { git -C "$PROJ" rev-parse HEAD "$BASE"
    git -C "$PROJ" diff --binary --no-renames HEAD -- "$CAPTURE_DIR"
    if [ -n "$untracked" ]; then
      printf '%s\n' "$untracked"
      printf '%s\n' "$untracked" | git -C "$PROJ" hash-object --no-filters --stdin-paths
    fi
  } 2>/dev/null | git hash-object --stdin
}

# capture_alive <pid>: true while <pid> is still the capture this sync started.
capture_alive() {
  [ -n "$1" ] || return 1
  case "$(ps -p "$1" -o command= 2>/dev/null)" in *"$CAPTURE_CMD"*) return 0 ;; esac
  return 1
}

# capture_running: load this checkout's capture record into CAPTURE_RECORD
# (empty when no key), CAPTURE_PRIOR and CAPTURE_PID; true while that capture
# is still alive.
capture_running() {
  local key
  CAPTURE_RECORD="" CAPTURE_PRIOR="" CAPTURE_PID=""
  key=$(live_record_key) || return 1
  CAPTURE_RECORD="$LIVE_RECORDS/$key.capture"
  [ ! -f "$CAPTURE_RECORD" ] || read -r CAPTURE_PRIOR CAPTURE_PID < "$CAPTURE_RECORD" || true
  capture_alive "$CAPTURE_PID"
}

# capture_or_report_stuck: for a live checkout whose uncommitted paths all lie
# under its capture=<dir>/, start the capture command once per edit state (see
# the header); otherwise report STUCK. sync_live_checkout has already deferred
# a checkout whose capture is still running.
capture_or_report_stuck() {
  local log fp rc="" pid
  if [ -z "$CAPTURE_CMD" ] || ! capture_paths_only \
      || ! fp=$(capture_fingerprint) || [ -z "$fp" ]; then
    report_stuck "$(stuck_state)"
    return 0
  fi
  capture_running || true
  if [ -z "$CAPTURE_RECORD" ]; then
    report_stuck "$(stuck_state)"
    return 0
  fi
  log="$CAPTURE_RECORD.log"
  if [ -n "$CAPTURE_PRIOR" ]; then
    rc=$(cat "$CAPTURE_RECORD.status" 2>/dev/null) || rc=""
  fi
  if [ "$CAPTURE_PRIOR" = "$fp" ]; then
    report_stuck "$(stuck_state)" "; capture already ran for these edits (exit ${rc:-unknown}, log $log)"
    return 0
  fi
  if ! mkdir -p "$LIVE_RECORDS" 2>/dev/null; then
    report_stuck "$(stuck_state)"
    return 0
  fi
  rm -f "$CAPTURE_RECORD.status"
  # set -m gives the run its own process group: bootstrap's timeout kills the
  # sync's group, and the capture must outlive it.
  # shellcheck disable=SC2016 # $1 and $2 expand in the detached shell
  pid=$(cd "$PROJ" && set -m && {
    nohup bash -c 'bash -c "$1"; echo $? > "$2"' fm-capture "$CAPTURE_CMD" "$CAPTURE_RECORD.status" \
      </dev/null >"$log" 2>&1 &
    echo $!
  }) || pid=""
  if [ -z "$pid" ]; then
    report_stuck "$(stuck_state)"
    return 0
  fi
  write_live_record "$CAPTURE_RECORD" "$fp $pid"
  # A failed capture still surfaces while the edits keep changing.
  if [ -n "$CAPTURE_PRIOR" ] && [ "${rc:-unknown}" != 0 ]; then
    report_stuck "$(stuck_state)" "; the last capture failed (exit ${rc:-unknown}), so $CAPTURE_CMD started again (log $log)"
    return 0
  fi
  echo "$label: capturing: $CAPTURE_COUNT uncommitted path(s) under $CAPTURE_DIR only; started $CAPTURE_CMD (log $log)"
}

# One config value of $PROJ's own .git, read without needing a work tree.
git_dir_config() {
  git --git-dir="$PROJ/.git" config --get "$1" 2>/dev/null || echo unset
}

# True when $PROJ is the root of its own work tree; otherwise prints the skip
# line, or a STUCK line when $PROJ has a .git that yields no work tree.
require_clone_root() {
  # Git repository discovery walks UP from $PROJ, so a plain directory merely
  # nested inside a repository - a worktree container left under projects/, say -
  # resolves to the ENCLOSING repository, which in a firstmate home is the
  # firstmate checkout itself. Every later `git -C "$PROJ"` would then read, prune
  # and fast-forward that repository under this project's label, turning a routine
  # refresh into an unrequested self-update reported as a project sync. Require
  # $PROJ to be the root of its own work tree before any other git command runs.
  proj_top=$(git -C "$PROJ" rev-parse --show-toplevel 2>/dev/null) || proj_top=""
  if [ -z "$proj_top" ]; then
    # A clone whose .git is present but yields no work tree is broken, not
    # absent - most often a stray core.bare=true or core.worktree in its own
    # config - and stays broken until someone looks, so say so loudly.
    if [ -e "$PROJ/.git" ]; then
      echo "$label: STUCK: has .git but git sees no work tree (core.bare=$(git_dir_config core.bare), core.worktree=$(git_dir_config core.worktree)) - needs attention"
      return 1
    fi
    echo "$label: skipped: not a git repo"
    return 1
  fi
  # Compare filesystem identity, not spelling: the question is whether git's root
  # and $PROJ are the same directory, and a string compare of the two paths also
  # fails when they merely differ in case (case-insensitive volume) or in how a
  # symlink is spelled.
  proj_abs=$(cd "$PROJ" && pwd -P) || proj_abs=""
  if [ -z "$proj_abs" ] || ! [ "$proj_top" -ef "$proj_abs" ]; then
    echo "$label: skipped: not a clone root (git would act on $proj_top)"
    return 1
  fi
  return 0
}

sync_project() {
  PROJ=$1
  label=$(project_label)
  CAPTURE_DIR="" CAPTURE_CMD=""

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  require_clone_root || return 0
  if ! mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null); then
    echo "$label: skipped: registry entry does not resolve to a delivery posture (run bin/fm-project-mode.sh $label for the refusal)"
    return 0
  fi
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  fast_forward_clone yes
}

# fast_forward_clone <prune yes|no>: fetch $PROJ's origin and fast-forward its
# default branch when safe, printing one outcome line under $label. Sets
# FF_CURRENT=yes only when the clone ends cleanly on its default branch at origin.
fast_forward_clone() {
  local prune_mode=$1
  FF_CURRENT=no
  if ! git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    echo "$label: skipped: no origin remote"
    return 0
  fi

  if ! fetch_with_packed_refs_lock_guard; then
    reason="fetch failed"
    if [ -n "$FETCH_OUTPUT" ]; then
      reason="$reason: $(first_line "$FETCH_OUTPUT")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi

  [ "$prune_mode" = no ] || prune_gone_branches || true

  DEFAULT=$(default_branch) || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }
  BASE="origin/$DEFAULT"
  if ! git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    echo "$label: skipped: $BASE does not exist"
    return 0
  fi

  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  dirty=no
  [ -z "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes
  recovered=no

  if [ "$cur" != "$DEFAULT" ]; then
    # Off the default branch. Auto-recover only the one unambiguously safe drift:
    # a clean, detached HEAD that holds no unique commits (it is an ancestor of
    # origin/<default>) and whose <default> branch is free to check out here.
    # Re-attaching to an already-published commit strands nothing, and the
    # fast-forward path below then catches the clone up. Anything else - a
    # non-default named branch, a detached HEAD with unique commits, a dirty tree,
    # or <default> already checked out elsewhere - may hold real work, so it is
    # reported loudly and left untouched.
    if [ -z "$cur" ] && [ "$dirty" = no ] \
        && git -C "$PROJ" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null \
        && ! default_checked_out_elsewhere \
        && local_default_safe_for_recovery; then
      if ! git -C "$PROJ" checkout --quiet "$DEFAULT" 2>/dev/null; then
        report_stuck "$(stuck_state)"
        return 0
      fi
      recovered=yes
      cur=$DEFAULT
    else
      report_stuck "$(stuck_state)"
      return 0
    fi
  elif [ "$dirty" = yes ]; then
    # On the default branch but with uncommitted changes we must not disturb.
    capture_or_report_stuck
    return 0
  fi

  if ! git -C "$PROJ" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null; then
    echo "$label: skipped: local $DEFAULT does not exist"
    return 0
  fi

  local_rev=$(git -C "$PROJ" rev-parse "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  remote_rev=$(git -C "$PROJ" rev-parse "$BASE") || {
    echo "$label: skipped: cannot read $BASE"
    return 0
  }
  if [ "$local_rev" = "$remote_rev" ]; then
    FF_CURRENT=yes
    if [ "$recovered" = yes ]; then
      echo "$label: recovered: re-attached $DEFAULT (already current)"
    else
      echo "$label: already current"
    fi
    return 0
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BASE"; then
    report_stuck "diverged $DEFAULT"
    return 0
  fi

  before=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: cannot read local $DEFAULT"
    return 0
  }
  if ! merge_output=$(git -C "$PROJ" merge --ff-only "$BASE" 2>&1); then
    reason="fast-forward failed"
    if [ -n "$merge_output" ]; then
      reason="$reason: $(first_line "$merge_output")"
    fi
    echo "$label: skipped: $reason"
    return 0
  fi
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT") || {
    echo "$label: skipped: fast-forward completed but cannot read local $DEFAULT"
    return 0
  }
  FF_CURRENT=yes
  if [ "$recovered" = yes ]; then
    echo "$label: recovered: re-attached $DEFAULT, synced $before..$after"
  else
    echo "$label: synced $before..$after"
  fi
  return 0
}

# shellcheck disable=SC2088 # the case patterns match a literal ~/ prefix
expand_home() {
  case "$1" in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# wait_for_lock_release <lock> <max-secs>: true once <lock> no longer exists,
# false when it still exists after waiting up to <max-secs>.
wait_for_lock_release() {
  local lock=$1 max=$2 waited=0
  while [ -e "$lock" ]; do
    [ "$waited" -lt "$max" ] || return 1
    sleep "$LIVE_LOCK_POLL_SECS"
    waited=$((waited + LIVE_LOCK_POLL_SECS))
  done
  return 0
}

# post_update_output_tail <file>: the last POST_UPDATE_TAIL_LINES non-blank
# lines of a post-update command's output, control characters removed, each
# cut to POST_UPDATE_TAIL_CHARS and joined with " / ", so the reason fits on
# the one STUCK line every relay reads.
post_update_output_tail() {
  local file=$1 line joined=""
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    [ -n "$joined" ] && joined="$joined / "
    joined="$joined$line"
  done < <(LC_ALL=C tr '\t\r' '  ' < "$file" | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | grep -v '^[[:space:]]*$' | tail -n "$POST_UPDATE_TAIL_LINES" \
    | LC_ALL=C cut -c "1-$POST_UPDATE_TAIL_CHARS")
  printf '%s\n' "$joined"
}

# run_post_update <command> <fast-forwarded yes|no>: run the entry's post-update
# command when the checkout's HEAD differs from the commit the command last
# succeeded for (see the header), recording HEAD after a success.
run_post_update() {
  local cmd=$1 moved=$2 key record head recorded="" rc=0 output tail
  head=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null) || return 0
  key=$(live_record_key) || return 0
  record="$LIVE_RECORDS/$key"
  [ ! -f "$record" ] || recorded=$(sed -n 1p "$record" 2>/dev/null)
  if [ -n "$recorded" ] && [ "$recorded" = "$head" ]; then
    return 0
  fi
  if [ -z "$recorded" ] && [ "$moved" = no ]; then
    write_live_record "$record" "$head"
    return 0
  fi
  # The command's output still reaches stderr, but it is also captured so a
  # failure carries its reason on stdout: bootstrap and the scheduled sync keep
  # only stdout's STUCK line.
  output=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync-post-update.XXXXXX" 2>/dev/null) || output=/dev/null
  (cd "$PROJ" && bash -c "$cmd") </dev/null >"$output" 2>&1 || rc=$?
  [ "$output" = /dev/null ] || cat "$output" >&2 || true
  if [ "$rc" -ne 0 ]; then
    # A first-sighting failure still leaves a record that matches no commit, so
    # the next sync retries rather than seeding the record as already deployed.
    [ -n "$recorded" ] || write_live_record "$record" pending
    tail=$(post_update_output_tail "$output")
    echo "$label: STUCK: post-update command failed (exit $rc) at $(git -C "$PROJ" rev-parse --short HEAD); the next sync retries it - needs attention${tail:+; last output: $tail}"
    [ "$output" = /dev/null ] || rm -f "$output"
    return 0
  fi
  [ "$output" = /dev/null ] || rm -f "$output"
  write_live_record "$record" "$head"
  echo "$label: post-update command ran at $(git -C "$PROJ" rev-parse --short HEAD)"
}

# live_record_key: the name of the current checkout's records under
# state/live-checkouts/.
live_record_key() {
  printf '%s' "$proj_abs" | git hash-object --stdin
}

write_live_record() {
  local record=$1 head=$2 tmp
  mkdir -p "$LIVE_RECORDS" 2>/dev/null || return 0
  tmp="$record.tmp.$$"
  if ! { printf '%s\n' "$head" > "$tmp" && mv -f "$tmp" "$record"; } 2>/dev/null; then
    rm -f "$tmp"
  fi
}

# sync_live_checkout <project> <path> <lock> <capture> <command> <lock-wait-secs>
sync_live_checkout() {
  local project=$1 path=$2 lock=$3 capture=$4 cmd=$5 wait_secs=$6 self before moved
  PROJ=$(expand_home "$path")
  label="$project live $path"
  CAPTURE_DIR="" CAPTURE_CMD=""
  if [ -n "$capture" ]; then
    CAPTURE_DIR=${capture%%:*}
    CAPTURE_DIR=${CAPTURE_DIR#./}
    CAPTURE_DIR="${CAPTURE_DIR%/}/"
    CAPTURE_CMD=$(expand_home "${capture#*:}")
    case "$CAPTURE_CMD" in */*) ;; *) CAPTURE_CMD="./$CAPTURE_CMD" ;; esac
  fi
  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  require_clone_root || return 0
  for self in "$FM_ROOT" "$FM_HOME"; do
    if [ "$proj_abs" = "$(cd "$self" 2>/dev/null && pwd -P)" ]; then
      echo "$label: skipped: this is the firstmate home; update it through /updatefirstmate"
      return 0
    fi
  done
  if [ -n "$lock" ]; then
    lock=$(expand_home "$lock")
    if ! wait_for_lock_release "$lock" "$wait_secs"; then
      echo "$label: skipped: busy: $lock is held; rerun bin/fm-fleet-sync.sh $project after it clears"
      return 0
    fi
  fi
  if [ -n "$CAPTURE_CMD" ] && capture_running; then
    echo "$label: skipped: busy: $CAPTURE_CMD is still running (log $CAPTURE_RECORD.log); the next sync retries"
    return 0
  fi
  before=$(git -C "$PROJ" rev-parse HEAD 2>/dev/null) || before=""
  fast_forward_clone no
  [ "$FF_CURRENT" = yes ] || return 0
  [ -n "$cmd" ] || return 0
  if [ "$(git -C "$PROJ" rev-parse HEAD 2>/dev/null)" = "$before" ]; then
    moved=no
  else
    moved=yes
  fi
  run_post_update "$cmd" "$moved"
}

# sync_live_checkouts <project-or-empty> <lock-wait-secs>: sync the configured
# live checkouts for one project, or every entry when the project is empty.
sync_live_checkouts() {
  local only=$1 wait_secs=$2 line project path lock capture cmd rest token n=0
  [ -f "$LIVE_CHECKOUTS_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in ''|'#'*) continue ;; esac
    project=${line%%[[:space:]]*}
    rest=${line#"$project"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    path=${rest%%[[:space:]]*}
    rest=${rest#"$path"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    if [ -z "$path" ]; then
      echo "live-checkouts: skipped: line $n names no path"
      continue
    fi
    [ -z "$only" ] || [ "$project" = "$only" ] || continue
    lock="" capture=""
    while :; do
      token=${rest%%[[:space:]]*}
      case "$token" in
        lock=*) lock=${token#lock=} ;;
        capture=*) capture=${token#capture=} ;;
        *) break ;;
      esac
      rest=${rest#"$token"}
      rest=${rest#"${rest%%[![:space:]]*}"}
    done
    case "$capture" in
      ''|[!:/]*:[!:]*) ;;
      *) capture=bad ;;
    esac
    case "${capture%%:*}" in ./|.|bad) capture=bad ;; esac
    if [ "$capture" = bad ]; then
      echo "live-checkouts: skipped: line $n capture= wants <dir>/:<command> with <dir> inside the checkout"
      continue
    fi
    cmd=$rest
    sync_live_checkout "$project" "$path" "$lock" "$capture" "$cmd" "$wait_secs"
  done < "$LIVE_CHECKOUTS_FILE"
}

if [ $# -eq 1 ]; then
  sync_project "$(resolve_project_arg "$1")"
  sync_live_checkouts "$(project_label)" "$LIVE_LOCK_WAIT_SECS"
  exit 0
fi

if [ ! -d "$PROJECTS" ]; then
  sync_live_checkouts "" 0
  exit 0
fi
for proj in "$PROJECTS"/*; do
  [ -e "$proj" ] || continue
  [ -d "$proj" ] || continue
  # Per-clone elapsed, so a fleet refresh that runs long names WHICH clone cost
  # the time instead of only its total. Recording is a no-op unless the deferred
  # network stage asked for it.
  __fm_timing_stamp=$(fm_timing_now_ms)
  sync_project "$proj"
  fm_timing_record clone sync "$__fm_timing_stamp" "$(basename "$proj")"
done
sync_live_checkouts "" 0
