# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the PRIMARY of the repo the given dir belongs
# to. The dir handed in is whatever checkout the fleet action is executing from,
# which is routinely a LINKED worktree (a crewmate task worktree on its own
# fm/<id> branch, a secondmate home), so the classification resolves the primary
# first rather than reading the caller's own branch. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout of the repo <dir> belongs to: git lists the main
# worktree first in `git worktree list`, ahead of every linked worktree. Echoes
# that path, or returns 1 when <dir> is not a git work tree at all or the repo's
# main worktree is bare, which has no checked-out branch to strand. Callers pass
# the checkout they happen to be executing from, so this is what keeps a linked
# worktree's own task branch from being classified as the primary's branch.
fm_primary_checkout_dir() {
  local dir=$1 line primary=
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) primary=${line#worktree } ;;
      bare) return 1 ;;
      '') break ;;
    esac
  done <<EOF
$(git -C "$dir" worktree list --porcelain 2>/dev/null)
EOF
  [ -n "$primary" ] && [ -d "$primary" ] || return 1
  printf '%s\n' "$primary"
  return 0
}

# If the primary checkout of the repo <dir> belongs to is tangled - on a NAMED
# branch that is not its default branch - echo the offending branch name and
# return 0. For every healthy state (not a git work tree, no non-bare primary,
# detached HEAD, or already on the default branch) echo nothing and return 1.
# Detached HEAD is how linked worktrees and secondmate homes legitimately sit, so
# they never trip this; only a feature branch checked out in the primary does.
# Pass the executing checkout: <dir> is resolved to its primary before classifying,
# so a task worktree on fm/<id> reports on the primary, never on itself.
fm_primary_tangle_branch() {
  local dir=$1 root cur default
  root=$(fm_primary_checkout_dir "$dir") || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  default=$(fm_default_branch "$root") || return 1
  [ "$cur" = "$default" ] && return 1
  printf '%s\n' "$cur"
  return 0
}
